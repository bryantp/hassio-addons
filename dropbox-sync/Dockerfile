FROM alpine:3.22

ENV LANG=C.UTF-8

# Pinned to a known-good commit of andreafabrizi/Dropbox-Uploader (API v2 + refresh tokens).
ARG DROPBOX_UPLOADER_SHA=11fb8f736064730dd21ff85d68dfcc8aacfdf559

RUN apk add --no-cache bash jq curl findutils python3 py3-requests py3-dateutil py3-tz

RUN curl -fsSL \
        "https://raw.githubusercontent.com/andreafabrizi/Dropbox-Uploader/${DROPBOX_UPLOADER_SHA}/dropbox_uploader.sh" \
        -o /dropbox_uploader.sh \
    && chmod a+x /dropbox_uploader.sh

COPY run.sh /
COPY keep_last.py /
RUN chmod a+x /run.sh

WORKDIR /

CMD [ "/run.sh" ]
