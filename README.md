# docker-parseacns-perl

## What is this for?

From [Office of Consumer Affairs (OCA)](http://www.ic.gc.ca/eic/site/oca-bc.nsf/eng/ca02920.html):

* On January 2, 2015, the Notice and Notice provisions of the Copyright Modernization Act came into force. 
* The Notice and Notice regime formalizes a voluntary practice aimed at discouraging online copyright infringement.

This script forwards copyright notices received in a mailbox, typically abuse@someisp.com, to downstream customers of an ISP that would have assigned blocks of IP addresses to said customers.

## What does it do?

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

## What does it need?

For convenience [Docker](https://www.docker.com/) is used to build a small container with perl interpreter. I tried keeping the container small by building on the minimalist debian:stretch-slim image. Without Docker, several additional perl modules are needed. They can be found on [CPAN](https://www.cpan.org/): Mail::IMAPClient, Email::Address, MIME::QuotedPrint, MIME::Base64, XML::XPath, Time::Piece, Net::IP::Lite, Net::SMTPS, Sys::Hostname.

## Building

Build it from Github

    git clone https://github.com/adilinden/docker-parseacns-perl.git
    docker build -t adilinden/parseacns-perl .

Or, get it from Docker Hub

    docker pull adilinden/parseacns-perl

## Configuration

Configuration variables as passed to the docker container and `parseacns.pl` script via environment variables. The most convenient way to do this is via an environment file. Create `config.env` based on the `src/environment-template.txt` (which is populated with default values).

The users IMAP and SMTP passwords need to be passed as environment variables also. I recomment the `.passwd.env` file for the task. A `.passwd.env` could look like this:

    IMAPPASS=some_password
    SMTPPASS=some_other_password

Since both files are passed to the container using the `--env-file` option, any available configuration variable can be specified in either file.

A list of IP address ranges and associated contact email needs to be passed to the script as well. This is in from of a text file passed via bind mount. A template example is provided in `src/ip-template.txt`. Please excuse the strange format. Perhaps I will update the file format to something more common, such as comma delimited some day. Create your local copy of IP blocks and related contacts as `ip-list.txt`.

## Running

Assuming all the configuration files have been created per the instructions in the previous *Configuration* step, the container can be run with the following command line:

    docker run --rm -it --env-file=config.env --env-file=.passwd.env -v "$(pwd)":/mnt adilinden/parseacns-perl

## Credits

* ACNS XML parsing: http://mpto.unistudios.com/xml/ParseNoticeXML.txt


