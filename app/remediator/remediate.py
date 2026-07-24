"""Railhead remediator: quarantines misbehaving pods on alert.

WHY THIS EXISTS (full reasoning in README.md):

A railhead-api pod whose connection pool is exhausted or whose database is
unreachable returns 500 on every /items request -- but its readiness probe hits
/health, which returns a hardcoded "ok" and never touches the database.
Kubernetes sees a healthy pod and keeps routing traffic to it forever.

A readiness probe that queried the database would stop the traffic, but would
NOT restore capacity: a pod failing readiness is still Running and still
matches the ReplicaSet's selector, so it still counts toward the replica count
and no replacement is created. (Moving the check to liveness just produces
CrashLoopBackOff instead.) No probe configuration produces a healthy
replacement -- removing the pod from the ReplicaSet's SELECTOR does.

/health is deliberately kept database-free so readiness answers "can I serve?"
rather than "is everything downstream healthy?".

WHAT IT DOES:
Alertmanager POSTs here. Every alert gets evidence gathered and reported to
Slack. One alert type also triggers an action: patch the pod's `app` label so
it drops out of BOTH the Service selector (traffic stops) and the ReplicaSet
selector (a replacement is created), leaving the pod running for inspection.
"""
import logging
import os
import time

import requests
from flask import Flask, jsonify, request
from kubernetes import client, config
from kubernetes.client.rest import ApiException

# --- configuration ---------------------------------------------------------
NAMESPACE = os.environ.get("NAMESPACE", "railhead")
DEPLOYMENT = os.environ.get("DEPLOYMENT", "railhead-api")
SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")

# Single source of truth for what we act on. Everything else reaching this
# webhook is observed and reported only. Deliberately NOT duplicated into
# Alertmanager routing, so the two can never drift apart.
AUTO_REMEDIATE_ALERTS = {"RailheadAPIPodErrorRate"}

QUARANTINED_AT = "railhead.io/quarantined-at"
QUARANTINE_ALERT = "railhead.io/quarantine-alert"

MIN_REMAINING_READY = 1        # never quarantine our last serving pod
MAX_QUARANTINES = 3            # more than this means the deployment is bad
QUARANTINE_WINDOW = 15 * 60    # ...within this many seconds
QUARANTINE_TTL = 60 * 60       # delete quarantined pods after this long

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("remediator")

config.load_incluster_config()
core = client.CoreV1Api()
apps = client.AppsV1Api()
app = Flask(__name__)


# --- helpers ---------------------------------------------------------------
def notify(message):
    log.info(message)
    if SLACK_WEBHOOK_URL:
        try:
            requests.post(SLACK_WEBHOOK_URL, json={"text": message}, timeout=5)
        except requests.RequestException as exc:
            log.warning("slack post failed: %s", exc)


def sweep_and_count():
    """Delete expired quarantined pods; return how many are still recent.

    One API call doing two jobs. The cluster is our state store -- restarting
    this service loses nothing, which matters because it runs a single replica.
    """
    now = int(time.time())
    recent = 0
    pods = core.list_namespaced_pod(NAMESPACE, label_selector=QUARANTINED_AT)
    for pod in pods.items:
        age = now - int(pod.metadata.labels[QUARANTINED_AT])
        if age > QUARANTINE_TTL:
            core.delete_namespaced_pod(pod.metadata.name, NAMESPACE)
            log.info("ttl sweep: deleted %s (age %ds)", pod.metadata.name, age)
        elif age <= QUARANTINE_WINDOW:
            recent += 1
    return recent


def get_pod(name):
    try:
        return core.read_namespaced_pod(name, NAMESPACE)
    except ApiException as exc:
        if exc.status == 404:
            return None
        raise


def ready_replicas():
    dep = apps.read_namespaced_deployment(DEPLOYMENT, NAMESPACE)
    return dep.status.ready_replicas or 0


def gather_evidence(pod):
    """Read-only. Runs BEFORE we change anything, so the Slack report shows
    the state that justified the decision."""
    status = (pod.status.container_statuses or [None])[0]
    try:
        logs = core.read_namespaced_pod_log(
            pod.metadata.name, NAMESPACE, tail_lines=30
        )
    except ApiException as exc:
        logs = f"(logs unavailable: {exc.status})"
    return {
        "phase": pod.status.phase,
        "restarts": status.restart_count if status else "?",
        "image": status.image.split("/")[-1] if status else "?",
        "logs": logs.strip()[-1200:],
    }


def quarantine(pod, alertname):
    """One patch. The `app` label sits in BOTH the Service selector and the
    ReplicaSet selector, so changing it stops traffic and forces a replacement
    in a single call."""
    core.patch_namespaced_pod(
        pod.metadata.name,
        NAMESPACE,
        {
            "metadata": {
                "labels": {
                    "app": pod.metadata.labels["app"] + "-quarantined",
                    # Epoch seconds, not ISO: Kubernetes label values cannot
                    # contain colons, so "2026-07-23T14:30:00Z" is rejected.
                    QUARANTINED_AT: str(int(time.time())),
                    QUARANTINE_ALERT: alertname,
                }
            }
        },
    )


# --- main flow -------------------------------------------------------------
def handle_alert(alert, recent, multi_pod):
    labels = alert.get("labels", {})
    name = labels.get("alertname", "unknown")
    pod_name = labels.get("pod")

    if name not in AUTO_REMEDIATE_ALERTS:
        notify(f":eyes: *{name}* observed. No automated action configured.")
        return

    if not pod_name:
        notify(f":warning: *{name}* has no `pod` label. Cannot identify a target.")
        return

    if multi_pod:
        notify(
            f":no_entry: Refusing to quarantine `{pod_name}`: multiple pods are "
            f"alerting simultaneously. This is a shared failure -- any "
            f"replacement would be equally broken. Needs a human."
        )
        return

    pod = get_pod(pod_name)
    if pod is None:
        notify(f":information_source: `{pod_name}` no longer exists. Nothing to do.")
        return

    if QUARANTINED_AT in (pod.metadata.labels or {}):
        log.info("%s already quarantined, skipping", pod_name)
        return

    ready = ready_replicas()
    if ready - 1 < MIN_REMAINING_READY:
        notify(
            f":no_entry: Refusing to quarantine `{pod_name}`: only {ready} ready "
            f"replica(s). Quarantining would leave nothing serving traffic."
        )
        return

    if recent >= MAX_QUARANTINES:
        notify(
            f":no_entry: Refusing to quarantine `{pod_name}`: {recent} quarantines "
            f"in the last {QUARANTINE_WINDOW // 60}m. This looks like a bad "
            f"deployment, not one bad pod. Needs a human."
        )
        return

    evidence = gather_evidence(pod)
    quarantine(pod, name)

    notify(
        f":hospital: Quarantined `{pod_name}` on *{name}*\n"
        f"> phase={evidence['phase']} restarts={evidence['restarts']} "
        f"image={evidence['image']}\n"
        f"Traffic stopped; ReplicaSet is creating a replacement. The pod is "
        f"still running for inspection and will be deleted in "
        f"{QUARANTINE_TTL // 60}m.\n"
        f"_A follow-up `resolved` alert means the quarantine worked, not that "
        f"the problem fixed itself._\n"
        f"```{evidence['logs']}```"
    )


@app.route("/webhook", methods=["POST"])
def webhook():
    payload = request.get_json(silent=True) or {}
    firing = [a for a in payload.get("alerts", []) if a.get("status") == "firing"]

    # Alertmanager groups related alerts into one payload. If more than one pod
    # is failing at once, the fault is shared (e.g. Postgres is down) and
    # quarantining cannot help -- every replacement inherits the same problem.
    targets = {
        a.get("labels", {}).get("pod")
        for a in firing
        if a.get("labels", {}).get("alertname") in AUTO_REMEDIATE_ALERTS
        and a.get("labels", {}).get("pod")
    }
    multi_pod = len(targets) > 1

    recent = sweep_and_count()
    for alert in firing:
        handle_alert(alert, recent, multi_pod)
    return jsonify({"received": len(firing)}), 200


@app.route("/healthz", methods=["GET"])
def healthz():
    return jsonify({"status": "ok"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
