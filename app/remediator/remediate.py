from flask import Flask, request, jsonify
from kubernetes import client, config
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("railhead-remediator")

try:
    config.load_incluster_config()
except Exception as e:
    logger.error(f"Could not load in-cluster Kubernetes config — is this running inside a pod with a valid ServiceAccount token? {e}")
    raise
v1 = client.CoreV1Api()

AUTO_REMEDIATE_ALERTS = {"KubePodCrashLooping"}
app = Flask(__name__)


def restart_pod(namespace, pod_name):
    try:
        v1.delete_namespaced_pod(name=pod_name, namespace=namespace)
        logger.info(f"Deleted pod {pod_name} in {namespace} — Kubernetes will recreate it.")
        return True
    except client.exceptions.ApiException as e:
        logger.error(f"Could not delete pod {pod_name}: {e}")
        return False


@app.route("/webhook", methods=["POST"])
def alertmanager_webhook():
    payload = request.get_json()

    for alert in payload.get("alerts", []):
        labels = alert.get("labels", {})
        alert_name = labels.get("alertname", "unknown")

        if alert.get("status") != "firing":
            continue
        if alert_name not in AUTO_REMEDIATE_ALERTS:
            logger.info(f"{alert_name} fired — not on the auto-fix list, leaving for a human.")
            continue

        namespace = labels.get("namespace")
        pod_name = labels.get("pod")
        if not namespace or not pod_name:
            logger.warning(f"{alert_name} fired but missing namespace/pod — leaving for a human.")
            continue

        logger.info(f"{alert_name} fired for pod {pod_name} — attempting restart.")
        restart_pod(namespace, pod_name)

    return jsonify({"status": "received"}), 200


@app.route("/healthz", methods=["GET"])
def health_check():
    return jsonify({"status": "ok"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
