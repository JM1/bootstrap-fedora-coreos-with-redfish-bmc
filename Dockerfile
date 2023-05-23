# Copyright (c) 2023 Jakob Meng, <jakobmeng@web.de>
# SPDX-License-Identifier: GPL-3.0-or-later

FROM registry.fedoraproject.org/fedora-minimal:rawhide

RUN microdnf -y update && \
  microdnf -y install httpd mod_ssl && \
  microdnf clean all

RUN /usr/libexec/httpd-ssl-gencerts

STOPSIGNAL SIGWINCH

ENTRYPOINT ["/usr/sbin/httpd"]

CMD ["-DFOREGROUND"]
