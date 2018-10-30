FROM debian:stretch-slim

MAINTAINER Adi Linden <adi@adis.ca>

# Build with:
#
#    docker build --no-cache -t perl-parseacns .
#
# Run with:
#
#    docker run --rm -it -e IMAPPASS='some.password' perl-parseacns

# Need these modules:
#
#    Mail::IMAPClient
#    Email::Address
#   *MIME::QuotedPrint
#    MIME::Base64
#    XML::XPath
#    Time::Piece
#   *Net::IP::Lite
#    Net::SMTPS
#   *Sys::Hostname
#
# *Installed via CPAN

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        make \
        cpanminus \
    	libmail-imapclient-perl \
    	libemail-address-perl \
    	libmime-base64-perl \
    	libxml-xpath-perl \
    	libtime-piece-perl \
    	libnet-smtps-perl \
    && cpanm MIME::QuotedPrint \
    && cpanm -v Net::IP::Lite \
    && cpanm Sys::Hostname \
    && apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false \
    && rm -fr /var/cache/apt/* /var/lib/apt/lists/* \
    && rm -fr ./cpanm /root/.cpanm /usr/src/perl /usr/src/App-cpanminus-1.7044* /tmp/*


COPY src/* /app/
WORKDIR /app

CMD ["/usr/bin/perl","parseacns.pl"]
