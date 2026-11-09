#!/usr/bin/env bash
postconf -M "rakazo/unix=rakazo unix - n n - - pipe flags=Rq user=nobody argv=/docker-init.d/rakazo-inbound-email \${recipient}"
postconf -P submission/inet/smtpd_tls_security_level=encrypt submission/inet/smtpd_sasl_auth_enable=yes
install -d -m 755 /etc/rakazo
(umask 077 && printf '%s' "${INBOUND_SECRET:-}" >/etc/rakazo/inbound-email-secret)
chown nobody /etc/rakazo/inbound-email-secret
(c=${POSTFIX_smtpd_tls_cert_file:-} t=$(stat -c %Y "${POSTFIX_smtpd_tls_cert_file:-}" 2>/dev/null || true)
while sleep 10; do
  n=$(stat -c %Y "$c" 2>/dev/null || true)
  if [[ $n != "$t" ]]; then t=$n; postfix reload || true; fi
done) &
