# Dev/test PBX peer (SPEC §3). Debian 12 no longer packages Asterisk, so we
# use Alpine's package, which is multi-arch (arm64 included). The sample
# config supplies asterisk.conf/modules.conf; we overlay our own dial plan
# and PJSIP config.
FROM alpine:3.20
# asterisk-srtp is a separate Alpine package and NOT a dependency: without
# it there is no res_srtp.so at all, and an endpoint with
# media_encryption=sdes then refuses every call with 488 rather than failing
# visibly (2026-09-16 — it looked like our SDP was wrong; the offer was
# fine and the PBX simply could not do SRTP).
RUN apk add --no-cache asterisk asterisk-srtp asterisk-sample-config asterisk-sounds-en
COPY pjsip.conf extensions.conf /etc/asterisk/
COPY pjsip-tls.conf /etc/asterisk/pjsip-tls.conf
COPY pjsip-lines.conf extensions-lines.conf voicemail.conf /etc/asterisk/
# ASTERISK_LINES=yes makes this a PBX that expects the light server to
# REGISTER one third-party SIP line per device rather than to trunk to it
# (SPEC §6 item 3c), for `make harness-pbx-lines`. The two configurations
# replace each other rather than combining: the trunk's `type=identify`
# would match our line INVITEs by source address before their From user was
# ever looked at, which is the same collision that makes -pbx-mode one mode
# or the other on a real exchange.
ARG ASTERISK_LINES=no
RUN if [ "$ASTERISK_LINES" = yes ]; then \
      cp /etc/asterisk/pjsip-lines.conf /etc/asterisk/pjsip.conf \
   && cp /etc/asterisk/extensions-lines.conf /etc/asterisk/extensions.conf \
   && if grep -q "^type=identify" /etc/asterisk/pjsip.conf; then \
        echo "the lines config still has an identify section; line INVITEs would be matched to it by source address"; exit 1; \
      fi; \
    fi
# ASTERISK_CODECS: what every endpoint allows, in preference order (default
# g722,ulaw,alaw). "ulaw,alaw" builds a narrowband-only PBX — the shape of
# a customer exchange without G.722 — for `NARROWBAND=1 make harness-trunk`.
ARG ASTERISK_CODECS=g722,ulaw,alaw
RUN allow="$(printf 'allow=%s\n' $(echo "$ASTERISK_CODECS" | tr ',' ' '))" \
 && awk -v allow="$allow" '/^allow=/ { if (!done) { printf "%s\n", allow; done=1 } next } /^\[/ { done=0 } { print }' \
      /etc/asterisk/pjsip.conf > /etc/asterisk/pjsip.conf.new \
 && mv /etc/asterisk/pjsip.conf.new /etc/asterisk/pjsip.conf \
 && grep -c "^allow=" /etc/asterisk/pjsip.conf
# ASTERISK_SRTP=yes puts media_encryption=sdes on the trunk endpoint, so the
# PBX offers and accepts SDES on the leg to us — the shape of a customer
# exchange with a secure trunk profile, for `TRUNK_SRTP=... make harness-trunk`
# (SPEC §6 near-term item 3a). Default no: a PBX without encryption is the
# thing our default -trunk-srtp=off has to keep working with.
ARG ASTERISK_SRTP=no
RUN if [ "$ASTERISK_SRTP" = yes ]; then \
      awk '/^\[dialpark\]$/ { d=1 } /^\[/ && !/^\[dialpark\]$/ { d=0 } { print } \
           d && /^type=endpoint$/ { print "media_encryption=sdes" }' \
        /etc/asterisk/pjsip.conf > /etc/asterisk/pjsip.conf.new \
   && mv /etc/asterisk/pjsip.conf.new /etc/asterisk/pjsip.conf \
   && grep -c "^media_encryption=sdes" /etc/asterisk/pjsip.conf; \
    fi
# ASTERISK_TLS=yes moves the trunk endpoint onto SIP/TLS with mutual
# authentication (see pjsip-tls.conf), for `TRUNK_TLS=1 make harness-trunk`
# (SPEC §6 near-term item 3b). Default no: most PBXs run an unencrypted
# trunk and that has to keep working.
ARG ASTERISK_TLS=no
RUN if [ "$ASTERISK_TLS" = yes ]; then \
      cat /etc/asterisk/pjsip-tls.conf >> /etc/asterisk/pjsip.conf \
   && awk '/^\[dialpark\]$/ { d=1 } /^\[/ && !/^\[dialpark\]$/ { d=0 } \
           d && /^contact=sip:/ { print "contact=sip:172.30.0.10:5062\\;transport=tls"; next } \
           { print } \
           d && /^type=endpoint$/ { print "transport=transport-tls" }' \
        /etc/asterisk/pjsip.conf > /etc/asterisk/pjsip.conf.new \
   && mv /etc/asterisk/pjsip.conf.new /etc/asterisk/pjsip.conf \
   && grep -c "transport-tls" /etc/asterisk/pjsip.conf; \
    fi
# res_srtp.so is a separate package (above); TLS is not — it comes from the
# OpenSSL Asterisk's pjproject is already linked against. Assert it is
# really there, because a missing res_pjsip transport module does not stop
# Asterisk, it just never listens and every call times out instead.
RUN if [ "$ASTERISK_TLS" = yes ]; then \
      ls /usr/lib/asterisk/modules/res_pjsip.so >/dev/null \
   && (ldd /usr/lib/asterisk/modules/res_pjsip.so | grep -q libssl \
       || ldd /usr/lib/libasteriskpj.so.2 2>/dev/null | grep -q libssl \
       || { echo "asterisk has no OpenSSL: TLS transports will not load"; exit 1; }); \
    fi
RUN chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk 2>/dev/null || true
EXPOSE 5060/udp 5060/tcp 5061/tcp
CMD ["asterisk", "-f", "-vvv", "-U", "asterisk", "-G", "asterisk"]
