#!/usr/bin/perl -w
#
# To process ACNS content we need to:
#
# - Read message from INBOX
# - Get message header
# - Find content we need, hint: MIME, base64 anyone?
# - Parse for ACNS XML content
# - Find ACNS parms we need
# - Lookup contact for IP address
# - Forward to contact
# - Send response to sender
# - Move message to appropriate folder
# - Expunge message
# - Rinse and repeat
#
# Left as exercise for the reader is to monitor mailbox for things left
# behind, which could be non-ACNS or something new thrown at us.
#
# Installation
# ------------
#
# On OSX install the any missing perl modules using the cpan command line
# tool.  Some things I needed:
#
#     sudo cpan install Mail::IMAPClient
#     sudo cpan install Net::IP::Lite
#     sudo cpan install Email::Address
#     sudo cpan install Net::SMTPS
#
#
# Input File
# ----------
# 
# In order to forward emails we need to lookup email addresses for subnets.
# An input file is required in the following format:
#
#     192.168.234.0/24    Flaming Broiler, ON Canada  #<jandoe@example.com>#
#     10.255.73.128/25    Rolling Thunder, MB Canada  #<joedoe@example.org>#
#
# The IP subnet and the email address enclosed in '#<' and '>#' are required.
#
#
# Credits
# -------
#
# http://mpto.unistudios.com/xml/ParseNoticeXML.txt
#

use strict;
use warnings;
use utf8;

# IMAP handling
use Mail::IMAPClient;
use Email::Address;
use MIME::QuotedPrint;
use MIME::Base64;
use XML::XPath;
use Time::Piece;

# IPv4 calculations
use Net::IP::Lite;

# Sending email via SMTP
use Net::SMTPS;
use Sys::Hostname;

# Define who we are
my $version = "0.9.5";
my $mailer  = "parseACNS";

#
# Define default values for all configurable options
#

# Turn debugging on or off
#
# Debug will do the following
#
#   o Create a special folder hierachy in IMAP folder $imapfolderdebug
#   o Sent email to $debug_to instead proper recipients
#
# Controlling Mail::IMAP and Net::SMTP flags is left a future exercise
#
my $debug = "0";                            # Debug on / off
my $debug_to = 'some.user@example.com';     # Replace destination address
my $debug_smtp = "0";                       # Sent SMTP on / off
my $debug_imap = "0";                       # Save/move IMAP on / off
my $debug_stdout = "0";                     # Dump to STDOUT on / off

# Number of ACNS messages to process per execution of script
my $acnscnt = 2;

# IP subnets to admin email reference
my $ourfile = "/mnt/ip-list.txt";

# IP space we own
my @ourcidr = (
    "192.168.0.0/16",
    "10.0.0.0/8"
);

# IMAP configuration options
my $imaphost            = "outlook.office365.com";
my $imapport            = "993";
my $imapssl             = "1";
my $imapuser            = 'some.user@example.com\abuse@example.com';
my $imappass            = '';
my $imapinbox           = "INBOX";
my $imapfolderforward   = "ProcessedForwarded";
my $imapfolderunkown    = "ProcessedUnknown";
my $imapfoldernotours   = "ProcessedNotOurs";
my $imapfolderdebug     = "DebugSaved";

# SMTP configuration options
my $smtphost            = "smtp.office365.com";
my $smtpport            = "587";
my $smtpssl             = 'starttls';
my $smtpuser            = 'some.user@example.com';
my $smtppass            = '';
my $smtpauth            = '1';

# Email specifics
my $replyfrom           = 'abuse@example.com';
my $replyforward        = "Infringing IP address has been assigned to an ISP "
                        . "(internet service provider). Notice has been forwarded "
                        . "to the ISP serving the subscriber.\n";
my $replyunknown        = "Infringing IP address cannot be associated with an "
                        . "enduser.\n";
my $replynotours        = "Infringing IP address is outside of the IP address "
                        . "ranges allocated to us by ARIN.\n";
my $forwardnote         = "This infringement notice has been forwarded to you because you "
                        . "are either the enduser or the service provider for the IP address "
                        . "identified in this notice.  If you are a service provider please "
                        . "forward this notice to the enduser. This infringement notice has "
                        . "been forwarded to you pursuant to the provisions of Sections 41.25 "
                        . "and 41.26 of the Canada Copyright Act.\n\n"
                        . "Office of Consumer Affairs (OCA) - Notice and Notice Regime\n"
                        . "http://www.ic.gc.ca/eic/site/oca-bc.nsf/eng/ca02920.html\n\n"
                        . "Bill C-11\n"
                        . "http://www.parl.gc.ca/HousePublications/Publication.aspx?DocId=5697419&File=4\n";

#
# Fetch any overriding values from environment
#

# Turn debugging on or off
if (defined $ENV{'DEBUG'}) { $debug = $ENV{'DEBUG'}; }
if (defined $ENV{'DEBUG_TO'}) { $debug_to = $ENV{'DEBUG_TO'}; }
if (defined $ENV{'DEBUG_SMTP'}) { $debug_smtp = $ENV{'DEBUG_SMTP'}; }
if (defined $ENV{'DEBUG_IMAP'}) { $debug_imap = $ENV{'DEBUG_IMAP'}; }
if (defined $ENV{'DEBUG_STDOUT'}) { $debug_stdout = $ENV{'DEBUG_STDOUT'}; }

# Number of ACNS messages to process per execution of script
if (defined $ENV{'ACNSCNT'}) { $acnscnt = $ENV{'ACNSCNT'}; }

# IP subnets to admin email reference
if (defined $ENV{'OURFILE'}) { $ourfile = $ENV{'OURFILE'}; }

# IP space we own
#     Cannot pass arrays to perl via environment. Instead provide a colon (:)
#     delimites string with multiple values. Example:
#         OURCIDR=10.23.50.0/24:192.168.223.128/25
if (defined $ENV{'OURCIDR'}) { @ourcidr = split /:/, $ENV{'OURCIDR'}; }

# IMAP configuration options
if (defined $ENV{'IMAPHOST'}) { $imaphost = $ENV{'IMAPHOST'}; }
if (defined $ENV{'IMAPPORT'}) { $imapport = $ENV{'IMAPPORT'}; }
if (defined $ENV{'IMAPSSL'}) { $imapssl = $ENV{'IMAPSSL'}; }
if (defined $ENV{'IMAPUSER'}) { $imapuser = $ENV{'IMAPUSER'}; }
if (defined $ENV{'IMAPPASS'}) { $imappass = $ENV{'IMAPPASS'}; }
if (defined $ENV{'IMAPINBOX'}) { $imapinbox = $ENV{'IMAPINBOX'}; }
if (defined $ENV{'IMAPFOLDERFORWARD'}) { $imapfolderforward = $ENV{'IMAPFOLDERFORWARD'}; }
if (defined $ENV{'IMAPFOLDERUNKOWN'}) { $imapfolderunkown = $ENV{'IMAPFOLDERUNKOWN'}; }
if (defined $ENV{'IMAPFOLDERNOTOURS'}) { $imapfoldernotours = $ENV{'IMAPFOLDERNOTOURS'}; }
if (defined $ENV{'IMAPFOLDERDEBUG'}) { $imapfolderdebug = $ENV{'IMAPFOLDERDEBUG'}; }

# SMTP configuration options
if (defined $ENV{'SMTPHOST'}) { $smtphost = $ENV{'SMTPHOST'}; }
if (defined $ENV{'SMTPPORT'}) { $smtpport = $ENV{'SMTPPORT'}; }
if (defined $ENV{'SMTPSSL'}) { $smtpssl = $ENV{'SMTPSSL'}; }
if (defined $ENV{'SMTPUSER'}) { $smtpuser = $ENV{'SMTPUSER'}; }
if (defined $ENV{'SMTPPASS'}) { $smtppass = $ENV{'SMTPPASS'}; }
if (defined $ENV{'SMTPAUTH'}) { $smtpauth = $ENV{'SMTPAUTH'}; }

# Email specifics
if (defined $ENV{'REPLYFROM'}) { $replyfrom = $ENV{'REPLYFROM'}; }
if (defined $ENV{'REPLYFORWARD'}) { $replyforward = $ENV{'REPLYFORWARD'}; }
if (defined $ENV{'REPLYUNKNOWN'}) { $replyunknown = $ENV{'REPLYUNKNOWN'}; }
if (defined $ENV{'REPLYNOTOURS'}) { $replynotours = $ENV{'REPLYNOTOURS'}; }
if (defined $ENV{'FORWARDNOTE'}) { $forwardnote = $ENV{'FORWARDNOTE'}; }

# Deal with passwords
if ($imappass eq '') {
    print "No IMAP password specified!\n";
    exit();
}
if ($smtppass eq '') {
    $smtppass = $imappass;
}

# Start our IMAP connection

# We need to call "connect" manually here.  When using the "Socket"
# parameter the "new" call will return a valid object even if
# authentication failed.  Instead we do not pass the "Server"
# parameter to "new" thus preventing it from implicitly calling
# "connect".  Calling "connect" ourselves we get the desired result.
my $imap = Mail::IMAPClient->new(
        User            => $imapuser,
        Password        => $imappass,
        Keepalive       => 1,
        Peek            => 1,
        Reconnectretry  => 1,
        Debug           => 0,
    ) or die "Cannot create IMAP object: $@\n";
$imap->Server($imaphost);
$imap->Port($imapport);
$imap->Ssl($imapssl);
$imap->connect() or die "Cannot connect to $imaphost as $imapuser: $@";

# Process the INBOX

# Only if there are messages
my $cnt = $imap->message_count($imapinbox);
if ($cnt > 0) {
    print "There are $cnt messages in $imapinbox\n";
} else {
    print "There are no messages in $imapinbox\n";
    $imap->logout();
    exit();
}

# Make sure we start with cleaned up folders
$imap->expunge($imapinbox);

# Make INBOX the current folder
$imap->select($imapinbox) 
    or die "Couldn't not select: $@\n";

# Get index of all messages
#my @msgseqs = $imap->search('ALL')
my @msgseqs = $imap->messages
    or die "Couldn't get messages: $@\n";

# Process each individual message
my $loopcnt = 0;
foreach my $msgseq (@msgseqs) {
    print "---------------  New Message ---------------\n";
    print "Processing message $msgseq with\n";
    print " ID " . $imap->get_header($msgseq, "Message-ID") . "\n";

    my $bstruct;    # body
    my $pstruct;    # parts
    my $body    = '';
    my $xmlstr  = '';
    my $srcip   = '';
    my $srcto   = '';

    # Disect message, including simple multipart messages
    $bstruct = $imap->get_bodystructure($msgseq);
    if (lc($bstruct->bodytype) eq "multipart") {

        # Get parts from multipart message
        foreach my $pstruct ($bstruct->bodystructure()) {
            if (lc($pstruct->bodytype) eq "multipart") {

                # The rabbit hole...
                next;
            }
            else {

                # Decode the body, returns false (empty) on non-text parts
                $body = decode_body($imap, $msgseq, $pstruct);
                if ($body) {
                    $xmlstr = extract_xml($body);
                    # Look no further, we have ACNS XML
                    if ($xmlstr) { last; }
                }
            }
        }
    }
    else {
        $body = decode_body($imap, $msgseq, $bstruct);
        if ($body) { $xmlstr = extract_xml($body); }
    }

    # See if any part of message had ACNS XML content
    if (! $xmlstr) {
        print "No ACNS XML found, skipping...\n";
        next;
    }

    # Extract infringing IP from ACSN XML
    $srcip = extract_ip($xmlstr);
    if (! $srcip) {
        print "No IP in ACSN XML, skipping...\n";
        next; 
    }
    print "Found $srcip in ACNS XML\n";

    # Match against our CIDR range
    if (! is_in_cidr($srcip)) {
        print "IP not in our CIDR range\n";
        do_not_ours($imap, $msgseq, $body);
    }
    # Match against our subnet data
    elsif ($srcto = get_email_for_address_from_file($srcip)) {
        print "IP has email $srcto\n";
        do_forward($imap, $msgseq, $body, $srcto);
    }
    else {
        print "IP has no email\n";
        do_unknown($imap, $msgseq, $body);
    }


    $loopcnt++;
    print "Processed $loopcnt ACNS notices\n";
    if ($loopcnt >= $acnscnt) {
        last;
    }

    sleep (1);
}

$imap->expunge($imapinbox);
$imap->close();
$imap->logout();

# Functions below

# Get proper sender address to formulate replies
sub reply_address {
    my ($imap, $msgseq) = @_;

    my $from = clean_address($imap->get_header($msgseq, "Reply-To"));
    if (! $from) {
        $from = clean_address($imap->get_header($msgseq, "From"));
    }
    return $from;
}

# Cleanup address
sub clean_address {
    my ($str) = @_;

    if ($str) {
        my @addresses = Email::Address->parse($str);
        return $addresses[0]->address;
    }
    return;
}

# Decode the message body or multipart part as body
#   returns entire body/part, or false (empty)
sub decode_body {
    my ($imap, $msgseq, $struct) = @_;
    my $body;

    if ($debug) {
        print "  Debug: Type: ".$struct->bodytype."/".$struct->bodysubtype.", Encoding: ".$struct->bodyenc()."\n";
    }

    # We can only deal with text type content
    if (lc($struct->bodytype) ne "text") {
        return;
    }

    if (lc($struct->bodyenc()) eq "base64") {
        $body = decode_base64($imap->bodypart_string($msgseq, $struct->id));
    }
    elsif (lc($struct->bodyenc()) eq "quoted-printable") {
        $body = decode_qp($imap->bodypart_string($msgseq, $struct->id));
    }
    else {
        $body = $imap->bodypart_string($msgseq, $struct->id);
    }
    return $body;
}

# Parse the body for ACNS XML
#   returns entire XML string, false (empty)
sub extract_xml {
    my ($body) = @_;
    my $isxml   = 0;
    my $isacns  = 0;
    my $xmlstr  = "";

    # Parse body and collect XML into $xmlstr
    for (split /\n/, $body) {

        # Detect XML start
        if (m/<\?xml.*?>/) {
            $isxml = 1;
        }

        # Detect ACNS start
        if (m/<Infringement .*>/) {
            $isacns = 1;
        }

        # Collect XML string
        if ($isxml && $isacns) {
            $xmlstr .= $_;
        }

        # Detect XML end
        if (m#</Infringement>#) {
            $isacns = 0;
        }
    }
    return $xmlstr;
}

# Parse XML for IP address
sub extract_ip {
    my ($xmlstr) = @_;

    # Parse the XML content
    my $xml = XML::XPath->new(xml => $xmlstr);
    return $xml->findvalue("/Infringement/Source/IP_Address");
}

# Notice is replied to - no email
sub do_not_ours {
    my ($imap, $msgseq, $body) = @_;
    my $msg;
    my $enc = "base64";   # '8bit' or 'base64'
    my $to;
    
    # Sending reply to sender of notice
    #$to = $imap->get_header($msgseq, "From");
    $to = reply_address($imap, $msgseq);

    # Construct the new reply message
    $msg = construct_reply($imap, $msgseq, $body, $to, $replynotours, $enc);

    # Send the message via SMTP
    dispatch_smtp($to, $replyfrom, $msg);

    # Save message to IMAP folder
    dispatch_imap($imap, $msgseq, $imapfoldernotours, $msg);

    # Move original message to folder
    move_imap($imap, $msgseq, $imapfoldernotours);
}

# Notice is replied to - no email
sub do_unknown {
    my ($imap, $msgseq, $body) = @_;
    my $msg;
    my $enc = "base64";   # '8bit' or 'base64'
    my $to;

    # Sending reply to sender of notice
    #$to = $imap->get_header($msgseq, "From");
    $to = reply_address($imap, $msgseq);

    # Construct the new reply message
    $msg = construct_reply($imap, $msgseq, $body, $to, $replyunknown, $enc);

    # Send the message via SMTP
    dispatch_smtp($to, $replyfrom, $msg);

    # Save message to IMAP folder
    dispatch_imap($imap, $msgseq, $imapfolderunkown, $msg);

    # Move original message to folder
    move_imap($imap, $msgseq, $imapfolderunkown);
}

# Notice is forwarded and replied
sub do_forward {
    my ($imap, $msgseq, $body, $to) = @_;
    my $msg;
    my $enc = "base64";   # '8bit' or 'base64'

    # Construct the new forwarded message
    $msg = construct_forward($imap, $msgseq, $body, $to, $enc);
    
    # Send the message via SMTP
    dispatch_smtp($to, $replyfrom, $msg);

    # Save message to IMAP folder
    dispatch_imap($imap, $msgseq, $imapfolderforward, $msg);

    # Sending reply to sender of notice
    #$to = $imap->get_header($msgseq, "From");
    $to = reply_address($imap, $msgseq);

    # Construct the new reply message
    $msg = construct_reply($imap, $msgseq, $body, $to, $replyforward, $enc);

    # Send the message via SMTP
    dispatch_smtp($to, $replyfrom, $msg);

    # Save message to IMAP folder
    dispatch_imap($imap, $msgseq, $imapfolderforward, $msg);

    # Move original message to folder
    move_imap($imap, $msgseq, $imapfolderforward);
}

# Construct reply header and body
sub construct_reply {
    my ($imap, $msgseq, $body, $to, $reply, $enc) = @_;
    my $hdr;
    my $bdy;

    # Body encoding, defaut 8bit
    $enc = defined $enc ? $enc : "8bit";

    # Start with the header
    $hdr  = "MIME-Version: 1.0\n";
    $hdr .= "From: " . $replyfrom . "\n";
    $hdr .= "To: $to\n";
    $hdr .= "Date: " . $imap->Rfc822_date(time()) . "\n";
    $hdr .= "Subject: RE: " . $imap->get_header($msgseq, "Subject") . "\n";
    $hdr .= "In-Reply-To: " . $imap->get_header($msgseq, "Message-ID") . "\n";
    $hdr .= "References: " . $imap->get_header($msgseq, "Message-ID") . "\n";
    $hdr .= "Message-ID: " . create_message_id() . "\n";
    $hdr .= "X-Mailer: $mailer/$version\n";
    $hdr .= "Content-Type: text/plain; charset=\"utf-8\"\n";
    $hdr .= "Content-Transfer-Encoding: $enc\n";
    $hdr .= "\n";

    # Construct the body
    $bdy  = "$reply\n";
    $bdy .= "\n";
    $bdy .= "-------- Original message --------\n";
    $bdy .= "From: " . $imap->get_header($msgseq, "From") . "\n";
    $bdy .= "To: " . $imap->get_header($msgseq, "To") . "\n";
    $bdy .= "Date: " . $imap->get_header($msgseq, "Date") . "\n";
    $bdy .= "Subject: " . $imap->get_header($msgseq, "Subject") . "\n";
    $bdy .= "\n";
    $bdy .= $body;
    $bdy .= "\n";

    # Assemble parts
    if ($enc eq "base64") {
        $bdy = encode_base64($bdy);
    }
    return $hdr.$bdy;
}

# Construct forward header and body
sub construct_forward {
    my ($imap, $msgseq, $body, $to, $enc) = @_;
    my $hdr;
    my $bdy;

    # Body encoding, defaut 8bit
    $enc = defined $enc ? $enc : "8bit";

    # Start with the header
    $hdr  = "MIME-Version: 1.0\n";
    $hdr .= "From: " . $replyfrom . "\n";
    $hdr .= "To: $to \n";
    $hdr .= "Reply-To: " . $imap->get_header($msgseq, "From") . "\n";
    $hdr .= "Date: " . $imap->Rfc822_date(time()) . "\n";
    $hdr .= "Subject: FW: " . $imap->get_header($msgseq, "Subject") . "\n";
    $hdr .= "Original-From: " . $imap->get_header($msgseq, "From") . "\n";
    $hdr .= "Original-Recipient: " . $imap->get_header($msgseq, "To") . "\n";
    $hdr .= "Original-Subject: " . $imap->get_header($msgseq, "Subject") . "\n";
    $hdr .= "Original-Message-ID: " . $imap->get_header($msgseq, "Message-ID") . "\n";
    $hdr .= "References: " . $imap->get_header($msgseq, "Message-ID") . "\n";
    $hdr .= "Message-ID: " . create_message_id() . "\n";
    $hdr .= "X-Mailer: $mailer/$version\n";
    $hdr .= "Content-Type: text/plain; charset=\"utf-8\"\n";
    $hdr .= "Content-Transfer-Encoding: $enc\n";
    $hdr .= "\n";

    # Construct the body
    $bdy  = $forwardnote;
    $bdy .= "\n";
    $bdy .= "---- BEGIN forwarded message ----\n";
    $bdy .= "From: " . $imap->get_header($msgseq, "From") . "\n";
    $bdy .= "To: " . $imap->get_header($msgseq, "To") . "\n";
    $bdy .= "Date: " . $imap->get_header($msgseq, "Date") . "\n";
    $bdy .= "Subject: " . $imap->get_header($msgseq, "Subject") . "\n";
    $bdy .= "\n";
    $bdy .= $body;
    $bdy .= "\n";
    $bdy .= "---- END forwarded message ----\n";

    # Assemble parts
    if ($enc eq "base64") {
        $bdy = encode_base64($bdy);
    }
    return $hdr.$bdy;
}

# Get the namespace
sub imap_namespace {
    my ($imap) = @_;

    my $prefix;
    my $seperator;

    # Namespace for source server
    $prefix = $imap->namespace->[0]->[0]->[0];
    $seperator = $imap->namespace->[0]->[0]->[1];

    return ($prefix, $seperator);
}

# Move message on IMAP server
sub move_imap {
    my ($imap, $msgseq, $folder) = @_;

    # Debug...
    if ($debug && ! $debug_imap) { 
        print "  Debug: Skip move IMAP\n";
        return; 
    }

    # Get full path to mailbox (mailbox created if it doesn't exist)
    my $box = create_mailbox($imap, $msgseq, $folder);

    # Move message
    if ($imap->move($box, $msgseq )) {
        print "Moved message $msgseq to $box\n";
        return "true";
    }
    print "Failed move message $msgseq to $box\n";
    return;
}

# Create IMAP folder - returns full path
sub create_mailbox {
    my ($imap, $msgseq, $folder) = @_;

    # Get namespace from server
    my ($pre, $sep) = imap_namespace($imap);

    # Build the folder/mailbox path
    my $box = $pre.$folder.$sep.year_month();

    # Debug...
    if ($debug) {
        # Sub the folder
        print "  Debug: Original folder: $box\n";
        $box = $imapinbox.$sep.$imapfolderdebug;        
        print "  Debug: Actual   folder: $box\n";
    }

        # Check if folder/mailbox needs to be created
    if (! $imap->exists($box)) {
        
        # Create folder/mailbox
        if ($imap->create($box)) {
            $imap->subscribe($box);
            print "Created and subscribed new folder/mailbox $box\n";
        }
    }
    return $box;
}

# Save message to IMAP folder
sub dispatch_imap {
    my ($imap, $msgseq, $folder, $msg) = @_;

    # Debug...
    if ($debug && ! $debug_imap) { 
        print "  Debug: Skip save IMAP\n";
        return; 
    }

    # Get full path to mailbox (mailbox created if it doesn't exist)
    my $box = create_mailbox($imap, $msgseq, $folder);

    # Append the message to the folder/mailbox
    if ($imap->append_string($box, $msg)) {
        print "Success saving $msgseq to $box\n";
        return "Success";
    }
    print "Failed to save $msgseq to $box\n";
    return;
}

# Send message using SMTP
sub dispatch_smtp {
    my ($to, $from, $msg) = @_;
    my $exit = "";

    # Debug...
    if ($debug) {
        # Sub the To: address
        print "  Debug: Original To: $to\n";
        print "  Debug: Actual   To: $debug_to\n";
        $to = $debug_to;

        # Dump to STDOUT
        if ($debug_stdout) { print "$msg\n"; }

        # Mute the SMTP send
        if (! $debug_smtp) { 
            print "  Debug: Skip send SMTP\n";
            return;
        }
    }

    print "Sending via SMTP to $to\n";

    my $smtp = Net::SMTPS->new(
        Host        => $smtphost,
        Port        => $smtpport,
        doSSL       => $smtpssl,
        Timeout     => 60,
        Debug       => 0,
        ) or die "Cannot connect to $smtphost: $@\n";

    $smtp->auth($smtpuser, $smtppass) 
        or die "Cannot authenticate $smtpuser: $@\n";

    $smtp->mail($from)
        or die "Cannot send mail from $from: $@\n";
    
    if (! $smtp->recipient($to)) {
        print "ERR>>> Recipient address $to is not accepted: $@\n";
        print "ERR>>> Server responded: ".$smtp->message()."\n";
        $smtp->quit;
        return;             # We pay attention and fix those
    }
    
    if (! $smtp->data) {
        print "ERR>>> DATA command was not accepted\n";
        print "ERR>>> Server responded: ".$smtp->message()."\n";
        $smtp->quit;
        exit;               # Probably a server issue, better quit outright
    }

    $smtp->datasend($msg);

    if (! $smtp->dataend()) {
        print "ERR>>> Mail was not accepted: $@\n";
        print "ERR>>> Server responded: ".$smtp->message()."\n";
        $smtp->quit;
        return;             # We pay attention and fix those
    }
    $smtp->quit;
    print "Mail was successfully sent to $to\n";
    return "true";
}

# Get year and month (for folder naming)
sub year_month {
    my $t;

    #$t  = localtime->year;
    #$t .= "-";
    #$t .= localtime->mon;

    $t = localtime->ymd;
    $t =~ s/(\d{1,4}-\d{1,2})-\d{1,2}/$1/g;

    return $t;
}

# Create a Message-ID
#
# From: https://www.jwz.org/doc/mid.html
#
# In summary, one possible approach to generating a Message-ID would be:
#
#    o Append "<".
#    o Get the current (wall-clock) time in the highest resolution
#      to which you have access (most systems can give it to you in 
#      milliseconds, but seconds will do);
#    o Generate 64 bits of randomness from a good, well-seeded random
#      number generator;
#    o Convert these two numbers to base 36 (0-9 and A-Z) and append 
#      the first number, a ".", the second number, and an "@". This 
#      makes the left hand side of the message ID be only about 21 
#      characters long.
#    o Append the FQDN of the local host, or the host name in the 
#      user's return address.
#    o Append ">".
#
# If the random number generator is good, this will reduce the odds 
# of a collision of message IDs to well below the odds that a cosmic 
# ray will cause the computer to miscompute a result. That means that 
# it's good enough.
#
# There are many other approaches. This is provided only as an example.
#
sub create_message_id {
    my $a;
    my $b;
    my $c;
    my $d;

    # Seconds since Epoch
    $a = base36(time());

    # 24 bytes of randomness
    $b .= int(rand(10)) for 1..24;
    $b = base36($b);

    # User and domain of sender
    ($c, $d) = $replyfrom =~ /(.*)@(.*)/;

    # Use hostname of system if we can
    if (hostname()) { $d = hostname() };

    return "<$a.$b.$c\@$d>";
}

# Chang enumeric value (base10) to a-z, 0-9 (base36)
sub base36 {
    my ($val) = @_;
    my $symbols = join '', '0'..'9', 'a'..'z';
    my $b36 = '';
    while ($val) {
        $b36 = substr($symbols, $val % 36, 1) . $b36;
        $val = int $val / 36;
    }
    return $b36 || '0';
}


# Find needle in haystack (IP in subnet) and return true if found
sub is_in_cidr {
    my ($ip) = @_;
    my $subnet;

    print "Searching in our CIDR\n";

    foreach $subnet (@ourcidr) {
        if (ip_in_range($ip, $subnet)) {

            # Verbose reporting
            print "Found in $subnet\n";

            return "true";
        }
    }
    return;
}

# Find needle in haystack (IP in subnet) and return email address
sub get_email_for_address_from_file {
    my ($ip) = @_;
    my $prefix;
    my $email;

    print "Searching in $ourfile\n";

    # Read data from file
    open(my $fh, "<", $ourfile) or die "Can't open < $ourfile: $!";
    while (<$fh>) {

        my $prefix = "";
        my $email = "";

        # Get IP prefix
        if (/^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\/\d{1,2})/) {
            $prefix = $1;
        }
        
        # Get Email
        if (/#<(.*)>#/) {
            $email = $1;
        }

        # Valid data requires both prefix and email
        if ($prefix && $email) {
            # Evaluate against IP address
            if (ip_in_range($ip, $prefix)) {            
                # Verbose reporting
                print "Found in $prefix with $email\n";

                # We have a match and can now return
                close($fh);
                return $email;
            }
        }
    }
    close($fh);
    return;
}

# End
