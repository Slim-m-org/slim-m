# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# The probe connector the supervisor's Docker tests run.
FROM busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
COPY probe.sh /probe.sh
USER 0
ENTRYPOINT ["/probe.sh"]
