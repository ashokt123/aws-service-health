// Terraform generates web/config.js on apply. If it's missing, the page runs in demo mode.
window.STATUS_CONFIG = {
  endpoint: "https://<id>.lambda-url.us-east-2.on.aws/health",
  region: "us-east-2",
  intervalMs: 5000,
  timeoutMs: 8000,
};
