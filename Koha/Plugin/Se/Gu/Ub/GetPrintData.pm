package Koha::Plugin::Se::Gu::Ub::GetPrintData;

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Members;
use C4::Members::Attributes;
use C4::Auth;
use Koha::DateUtils;
use Koha::Libraries;
use Koha::Patron::Categories;
use Koha::Account;
use Koha::Account::Lines;
use MARC::Record;
use Cwd qw(abs_path);
use URI::Escape qw(uri_unescape);
use LWP::UserAgent;
use C4::Biblio;         # GetBiblioData GetMarcPrice
use LWP::Simple::Post qw(post);
use LWP::UserAgent;
use URI::Escape;
use Koha::Libraries;
use Koha::AuthorisedValues;
use utf8;
use Encode qw(decode encode);

## Here we set our plugin version
our $VERSION = "0.01";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Get Print Data Plugin',
    author          => 'Johan Larsson',
    date_authored   => '2017-10-02',
    date_updated    => '2017-10-02',,
    minimum_version => '17.05',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Makes an API-call to bestall-api that will print the reservenote',
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}



sub add_reserve_after {
    my ($self, $args) = @_;
    ## send request to bestall for printing info here
    my $api_url = $self->retrieve_data('api_url');
    my $api_key = $self->retrieve_data('api_key');

    if (!$api_url) {
        return $args;
    }
    if (!$api_key) {
        return $args;
    }

    ## Get biblio
    my $biblio = $args->{'hold'}->biblio();
    my $item = $args->{'hold'}->item();
    if (!$item) {
        return $args;
    }
    if ($item->onloan()) {
        return $args;
    }

    my $item_number = $item->itemnumber();
    my $priority = $args->{'hold'}->priority();
    my $holds = $biblio->holds();
    my $lowest_found_priority = undef;
    foreach my $hold (@{$holds->unblessed}) {
        if ($hold->{'itemnumber'} && $hold->{'itemnumber'} == $item_number) {
            if ($hold->{'priority'} == 0) {
                return $args;
            }
            if (!$lowest_found_priority) {
                $lowest_found_priority = $hold->{'priority'};
            }
            else {
                if ($lowest_found_priority > $hold->{'priority'}) {
                    $lowest_found_priority = $hold->{'priority'};
                }
            }
        }
    }
    if ($lowest_found_priority != $priority) {
        return $args;
    }
    my $borrower = $args->{'hold'}->borrower();
    my $sublocation = Koha::Libraries->find($item->location());
    my $location_name = Koha::Libraries->find($item->homebranch())->branchname;
    my $pickup_location_name = Koha::Libraries->find($args->{'hold'}->branchcode())->branchname;
    my $borrower_attributes = C4::Members::Attributes::GetBorrowerAttributes($borrower->borrowernumber());
    # filter out only code==PRINT
    my @filtered_borrower_attributes = ();
    foreach my $attr (@$borrower_attributes) {
        if ($attr->{code} eq 'PRINT') {
            #PUSH VALUE TO ARRAY
            push @filtered_borrower_attributes, $attr->{value};
        }
    }
    my $print_str = join(':', @filtered_borrower_attributes);
    my $category_auth_value = 'LOC';
    my $av = Koha::AuthorisedValues->find( {
        category => $category_auth_value,
        authorised_value =>  $item->permanent_location(),
    });


    my $record = GetMarcBiblio({
            biblionumber => $biblio->biblionumber,
            embed_items => 1 });
    my $marcflavour = C4::Context->preference('marcflavour');

    # get title based on marcdata
    my @title_arr = grep defined, ($record->subfield( '245', 'a' ),$record->subfield( '245', 'b' ), $record->subfield( '245', 'c' ));
    my $title = join(' ', @title_arr);

    # get subtitle based on marcdata
    my @alt_title_arr = grep defined, ($record->subfield( '245', 'n' ), $record->subfield( '245', 'p' ));
    my $alt_title = join(' ', @alt_title_arr);

    # get serie based on marcdata
    my @serie_arr = ();
    if ($record->subfield( '440', 'a' ) || $record->subfield( '440', 'v' ) || $record->subfield( '440', 'n' )) {
        @serie_arr = grep defined, ($record->subfield( '440', 'a' ), $record->subfield( '440', 'v' ), $record->subfield( '440', 'n' ));
    }
    else {
        @serie_arr = grep defined, ($record->subfield( '490', 'a' ), $record->subfield( '490', 'v' ));
    }
    my $serie = join(' ', @serie_arr);

    # get edition
    my $edition = $record->subfield( '250', 'a' );

    # get callnumber
    my $call_number = undef;
    if ($item->itemcallnumber()) {
      $call_number = $item->itemcallnumber();
    }
    else {
      $call_number = $record->subfield( '095', 'a' );
    }

    # get place
    my $place = undef;
    if ($record->subfield( '260', 'a' )) {
        $place = $record->subfield( '260', 'a' );
    }
    else {
        $place = $record->subfield( '264', 'a' );
    }

    # add year to place
    my $field_008 = $record->field('008')->data();
    my $year = substr $field_008, 7, 4;
    $place = $place . ' ' . $year;

    ## find correct loantype in string
    my $reserve_notes = $args->{'hold'}->reservenotes();
    my ($loantype) = $reserve_notes =~ /^L.netyp: ?(.*)$/m;

    ## construct hash for API
    my %fields = (
        "location" => Encode::encode('UTF-8', $location_name, Encode::FB_CROAK),
        "sublocation" => Encode::encode('UTF-8', $av->lib(), Encode::FB_CROAK),
        "sublocation_id" => $item->permanent_location(),
        "call_number" => Encode::encode('UTF-8', $call_number, Encode::FB_CROAK),
        "barcode" => $item->barcode(),
        "biblio_id" => $biblio->biblionumber(),
        "author" => Encode::encode('UTF-8', $biblio->author(), Encode::FB_CROAK),
        "title" => Encode::encode('UTF-8', $title, Encode::FB_CROAK),
        "alt_title" => Encode::encode('UTF-8', $alt_title, Encode::FB_CROAK),
        "volume" => Encode::encode('UTF-8', $item->enumchron(), Encode::FB_CROAK),
        "place" => Encode::encode('UTF-8', $place , Encode::FB_CROAK),
        "edition" => Encode::encode('UTF-8', $edition, Encode::FB_CROAK),
        "serie" => Encode::encode('UTF-8', $serie , Encode::FB_CROAK),
        "description" => Encode::encode('UTF-8', $args->{'hold'}->reservenotes(), Encode::FB_CROAK),
        "loantype" => Encode::encode('UTF-8', $loantype, Encode::FB_CROAK),
        "extra_info" => Encode::encode('UTF-8', $print_str, Encode::FB_CROAK),
        "name" => Encode::encode('UTF-8', $borrower->firstname() . ' ' . $borrower->surname(), Encode::FB_CROAK),
        "borrowernumber" => $borrower->borrowernumber(),
        "pickup_location" =>Encode::encode('UTF-8', $pickup_location_name, Encode::FB_CROAK),
        "reserve_id" => $args->{'hold'}->reserve_id(),
    );


    ## construct query as string
    my $query = '?';
    foreach my $key (keys %fields) {
        my $val = '';
        if ($fields{$key}) {
            $val = $fields{$key};
        }
        $query .= $key . '=' . uri_escape($val) . '&';
    }
    my $response = post($api_url .  $query . 'api_key=' . $api_key );
    ## if something goes wrong dump to file and continue
    if (!$response) {
        my $handle;
        my $filename =  $self->retrieve_data('log_file_path') . 'add_reserve_after-' . localtime() . '.log';
        $filename =~ s/\s//g;
        use Data::Dumper;
        open ($handle, '>' . $filename);
        print $handle Dumper(%fields);
        close ($handle) or die ("Unable to close file");
    }
    return $args;
}


## If your tool is complicated enough to needs it's own setting/configuration
## you will want to add a 'configure' method to your plugin like so.
## Here I am throwing all the logic into the 'configure' method, but it could
## be split up like the 'report' method is.
sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};


    my $libraries = Koha::Libraries->as_list();

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            api_url => $self->retrieve_data('api_url'),
            api_key => $self->retrieve_data('api_key'),
            log_file_path => $self->retrieve_data('log_file_path'),
        );
        print $cgi->header(-charset => 'utf-8' );
        print $template->output();
    }
    else {
        $self->store_data(
            {
                api_url => $cgi->param('api_url'),
                api_key => $cgi->param('api_key'),
                log_file_path => $cgi->param('log_file_path'),
            }
        );
        $self->go_home();
    }
}



sub install {
    my ($self, $args) = @_;
    return 1;
}

sub uninstall {
    my ($self, $args) = @_;
    return 1;
}



1;
