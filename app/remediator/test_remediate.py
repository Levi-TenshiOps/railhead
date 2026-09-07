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
def test_multi_pod_is_derived_from_a_payload_holding_both_pods(patched):
    """The synthetic case, at the HTTP layer rather than by hand.

    `test_refuses_when_multiple_pods_are_alerting` above passes `multi_pod`
    in as a parameter, so it never exercises the code that computes it. This
    one posts a real payload to /webhook and lets `webhook()` derive it. It
    passes -- which is exactly what the synthetic guard test proved, and
    exactly what turned out not to matter. See the next test.
    """
    core, _, messages = patched
    other = {
        "status": "firing",
        "labels": {"alertname": "RailheadAPIPodErrorRate", "pod": "railhead-api-def456"},
    }

    with remediate.app.test_request_context("/webhook", json={"alerts": [ALERT, other]}):
        remediate.webhook()

    core.patch_namespaced_pod.assert_not_called()
    assert all("multiple pods are alerting" in m for m in messages)


@pytest.mark.xfail(
    strict=True,
    reason="the multi_pod guard does not engage against real Alertmanager "
           "sequencing; see docs/known-gotchas.md #32",
)
def test_real_alertmanager_sequencing_defeats_the_multi_pod_guard(patched):
    """THIS TEST FAILS ON PURPOSE. It asserts the behaviour the guard is
    supposed to have, against the payloads Alertmanager actually sends.

    The test above passes because a hand-written payload carries both pods at
    once. Real Alertmanager never sends that payload during a shared outage.
    Week 7 measured what it sends instead:

      1. The two pods' `for: 2m` timers desynchronise (65s apart measured), so
         the first notification carries ONE firing pod. multi_pod is correctly
         False and pod A is quarantined.
      2. Quarantining A rewrites its `app` label, dropping it from the Service.
         The ServiceMonitor scrapes through the Service, so Prometheus stops
         scraping A and A's alert RESOLVES.
      3. One `group_interval` later (300s measured) the second notification
         arrives carrying A as *resolved* and B as *firing*. `webhook()` counts
         only firing alerts, so multi_pod is False again and B is quarantined
         too.

    Measured result: both api pods quarantined 300s apart, zero refusals,
    during exactly the shared-dependency outage the guard exists to prevent.

    Kept as an xfail rather than deleted or "fixed" because the measured
    behaviour is the artifact of this project. `strict=True` means this starts
    FAILING the build the day the guard is repaired, which is the point: the
    fix and this write-up cannot drift apart silently. The recommended repair
    is to count pods recently ACTED ON rather than pods currently FIRING,
    reusing the 15-minute history `sweep_and_count()` already keeps.
    """
    core, _, _ = patched
    pod_a = "railhead-api-abc123"
    pod_b = "railhead-api-def456"
    core.read_namespaced_pod.side_effect = lambda name, ns, **kw: make_pod(name=name)

    def alert(pod, status):
        return {
            "status": status,
            "labels": {"alertname": "RailheadAPIPodErrorRate", "pod": pod},
        }

    # Notification 1: only A has crossed its `for: 2m` timer.
    with remediate.app.test_request_context("/webhook", json={"alerts": [alert(pod_a, "firing")]}):
        remediate.webhook()

    # Notification 2, one group_interval later: A has resolved because
    # quarantining it took it out of the Service and out of Prometheus.
    with remediate.app.test_request_context(
        "/webhook", json={"alerts": [alert(pod_a, "resolved"), alert(pod_b, "firing")]}
    ):
        remediate.webhook()

    # What the guard is supposed to do: quarantine A, then refuse on B.
    core.patch_namespaced_pod.assert_called_once()
