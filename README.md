## parseACNS

### What is this for?

From [Office of Consumer Affairs (OCA)](http://www.ic.gc.ca/eic/site/oca-bc.nsf/eng/ca02920.html):

* On January 2, 2015, the Notice and Notice provisions of the Copyright Modernization Act came into force. 
* The Notice and Notice regime formalizes a voluntary practice aimed at discouraging online copyright infringement.

This script forwards copyright notices received in a mailbox, typically abuse@someisp.com, to downstream customers of an ISP that would have assigned blocks of IP addresses to said customers.

### What does it do?

An overview of what the perl script does:

- Read message from INBOX
- Get message header
- Find content we need, hint: MIME, base64 anyone?
- Parse for ACNS XML content
- Find ACNS parms we need
- Lookup contact for IP address
- Forward to contact
- Send response to sender
- Move message to appropriate folder
- Expunge message
- Rinse and repeat

### What does it need?

For convenience [Docker](https://www.docker.com/) is used to build a small container with perl interpreter. I tried keeping the container small by building on the minimalist debian:stretch-slim image. Without Docker, several additional perl modules are needed. They can be found on [CPAN](https://www.cpan.org/): Mail::IMAPClient, Email::Address, MIME::QuotedPrint, MIME::Base64, XML::XPath, Time::Piece, Net::IP::Lite, Net::SMTPS, Sys::Hostname.

### Building

Build it using `docker build -t perl-parseacns .`.

### Configuration

TBD

### Credits

* ACNS XML parsing: http://mpto.unistudios.com/xml/ParseNoticeXML.txt


