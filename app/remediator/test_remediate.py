"""Tests for the remediator's safety guards.

These exist because the guards are the whole reason this service is safe to
run unattended: it takes a destructive-looking action (relabeling a pod out of
its Service) with no human in the loop. Each guard below encodes a case where
acting would make things worse rather than better, and a regression in any of
them is silent -- the service would still return 200 and still post to Slack,
it would just quarantine something it shouldn't have.

`remediate` calls `config.load_incluster_config()` at import time, which is
correct for the real deployment and means the module cannot be imported
outside a cluster without patching first. That is what the `mock.patch` block
below is for.
"""
import sys
from pathlib import Path
from unittest import mock

import pytest

sys.path.insert(0, str(Path(__file__).parent))

with mock.patch("kubernetes.config.load_incluster_config"), mock.patch(
    "kubernetes.client.CoreV1Api"
), mock.patch("kubernetes.client.AppsV1Api"):
    import remediate


ALERT = {
    "status": "firing",
    "labels": {"alertname": "RailheadAPIPodErrorRate", "pod": "railhead-api-abc123"},
}


def make_pod(name="railhead-api-abc123", labels=None):
    pod = mock.MagicMock()
    pod.metadata.name = name
    pod.metadata.labels = labels if labels is not None else {"app": "railhead-api"}
    pod.status.phase = "Running"
    pod.status.container_statuses = [mock.MagicMock(restart_count=0, image="x/api:tag")]
    return pod


@pytest.fixture
def patched(monkeypatch):
    """Isolate the module from Kubernetes and Slack, and record what it did."""
    core = mock.MagicMock()
    apps = mock.MagicMock()
    messages = []

    core.read_namespaced_pod.return_value = make_pod()
    core.read_namespaced_pod_log.return_value = "boom"
    apps.read_namespaced_deployment.return_value.status.ready_replicas = 2

    monkeypatch.setattr(remediate, "core", core)
    monkeypatch.setattr(remediate, "apps", apps)
    monkeypatch.setattr(remediate, "notify", messages.append)
    return core, apps, messages


def test_quarantines_a_single_failing_pod(patched):
    """The case the service exists for: one bad pod, healthy siblings."""
    core, _, messages = patched

    remediate.handle_alert(ALERT, recent=0, multi_pod=False)

    core.patch_namespaced_pod.assert_called_once()
    patch_body = core.patch_namespaced_pod.call_args[0][2]
    assert patch_body["metadata"]["labels"]["app"] == "railhead-api-quarantined"
    assert "Quarantined" in messages[0]


def test_refuses_when_multiple_pods_are_alerting(patched):
    """A shared failure. Any replacement inherits the same broken dependency,
    so quarantining trades a diagnosable pod for an identical one."""
    core, _, messages = patched

    remediate.handle_alert(ALERT, recent=0, multi_pod=True)

    core.patch_namespaced_pod.assert_not_called()
    assert "multiple pods are alerting" in messages[0]


def test_refuses_when_it_would_leave_nothing_serving(patched):
    """One ready replica means quarantining takes the service to zero. A
    degraded pod still serving some traffic beats no pod at all."""
    core, apps, messages = patched
    apps.read_namespaced_deployment.return_value.status.ready_replicas = 1

    remediate.handle_alert(ALERT, recent=0, multi_pod=False)

    core.patch_namespaced_pod.assert_not_called()
    assert "only 1 ready" in messages[0]


def test_refuses_past_the_rate_limit(patched):
    """Three quarantines in fifteen minutes is a bad deployment, not three
    unlucky pods -- continuing would chew through the ReplicaSet one pod at a
    time while never fixing the cause."""
    core, _, messages = patched

    remediate.handle_alert(ALERT, recent=remediate.MAX_QUARANTINES, multi_pod=False)

    core.patch_namespaced_pod.assert_not_called()
    assert "looks like a bad deployment" in messages[0]


def test_ignores_alerts_it_is_not_configured_to_act_on(patched):
    """Every alert reaches this webhook; only one is actionable. The rest are
    reported and left alone."""
    core, _, messages = patched
    other = {"status": "firing", "labels": {"alertname": "KubePodCrashLooping"}}

    remediate.handle_alert(other, recent=0, multi_pod=False)

    core.patch_namespaced_pod.assert_not_called()
    assert "No automated action configured" in messages[0]


def test_one_failing_alert_does_not_sink_the_rest_of_the_payload(patched):
    """Alertmanager groups alerts. An exception on the first must not silence
    the ones behind it -- the Slack report is the only signal a human gets."""
    core, _, messages = patched
    core.read_namespaced_pod.side_effect = [RuntimeError("api blew up"), make_pod()]

    with remediate.app.test_request_context(
        "/webhook", json={"alerts": [ALERT, ALERT]}
    ):
        remediate.webhook()

    # First alert raised and was swallowed; the second still quarantined.
    core.patch_namespaced_pod.assert_called_once()
