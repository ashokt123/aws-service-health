PROFILE ?= multicloud
REGION  ?= us-east-2
PARAM   ?= /service-health/maintenance
TF      := terraform -chdir=infra

.PHONY: init plan deploy destroy outage recover status web

init:
	$(TF) init

plan:
	$(TF) plan -out=tfplan

deploy: plan
	$(TF) apply tfplan

destroy:
	$(TF) destroy

# Kill switch: API returns 503 within ~5s, alarm emails within ~1-2 min.
outage:
	aws ssm put-parameter --name $(PARAM) --value true --overwrite --profile $(PROFILE) --region $(REGION)

recover:
	aws ssm put-parameter --name $(PARAM) --value false --overwrite --profile $(PROFILE) --region $(REGION)

status:
	curl -s "$$($(TF) output -raw health_url)" ; echo

web:
	cd web && python3 -m http.server 8000
