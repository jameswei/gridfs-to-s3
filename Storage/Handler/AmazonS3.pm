package Storage::Handler::AmazonS3;

# class for storing / loading files from / to Amazon S3

use strict;
use warnings;

use Moose;
with 'Storage::Handler';

use Net::Amazon::S3;
use Net::Amazon::S3::Client;
use Net::Amazon::S3::Client::Bucket;

use Storage::Iterator::AmazonS3;

# Should the Amazon S3 module use secure (SSL-encrypted) connections?
use constant AMAZON_S3_USE_SSL => 0;

# How many seconds should the module wait before bailing on a request to S3 (in seconds)
use constant AMAZON_S3_TIMEOUT => 10;

# Check if content exists before PUTting (good for debugging, slows down the stores)
use constant AMAZON_S3_CHECK_IF_EXISTS_BEFORE_PUTTING => 1;

# Check if content exists before GETting (good for debugging, slows down the fetches)
use constant AMAZON_S3_CHECK_IF_EXISTS_BEFORE_GETTING => 1;

# Check if content exists before DELETing (good for debugging, slows down the fetches)
use constant AMAZON_S3_CHECK_IF_EXISTS_BEFORE_DELETING => 1;


# Configuration
my $_config_access_key_id;
my $_config_secret_access_key;
my $_config_bucket_name;
my $_config_folder_name;

# Net::Amazon::S3 instance, bucket (lazy-initialized to prevent multiple forks using the same object)
my $_s3                       = undef;
my $_s3_client                = undef;
my $_s3_bucket                = undef;

# Process PID (to prevent forks attempting to clone the Net::Amazon::S3 accessor objects)
my $_pid = 0;


# Constructor
sub BUILD {
    my $self = shift;
    my $args = shift;

    $_config_access_key_id = $args->{access_key_id} or die "Access key ID is not defined.";
    $_config_secret_access_key = $args->{secret_access_key} or die "Secret access key is not defined.";
    $_config_bucket_name = $args->{bucket_name} or die "Folder name is not defined.";
    $_config_folder_name = $args->{folder_name} || '';

    # Add slash to the end of the folder name (if it doesn't exist yet)
    if ( $_config_folder_name and substr( $_config_folder_name, -1, 1 ) ne '/' )
    {
        $_config_folder_name .= '/';
    }
}

# Destructor
sub DEMOLISH
{

    # Setting instances to undef should take care of the cleanup automatically
    $_s3_bucket = undef;
    $_s3_client = undef;
    $_s3        = undef;
    $_pid       = 0;
}

sub _initialize_s3_or_die
{
    my ( $self ) = @_;

    if ( $_pid == $$ and ( $_s3 and $_s3_bucket ) )
    {

        # Already initialized on the very same process
        return;
    }

    # Initialize
    $_s3 = Net::Amazon::S3->new(
        aws_access_key_id     => $_config_access_key_id,
        aws_secret_access_key => $_config_secret_access_key,
        retry                 => 1,
        secure                => AMAZON_S3_USE_SSL,
        timeout               => AMAZON_S3_TIMEOUT
    );
    unless ( $_s3 )
    {
        die "Unable to initialize Net::Amazon::S3 instance with access key '$_config_access_key_id'.";
    }
    $_s3_client = Net::Amazon::S3::Client->new( s3 => $_s3 );

    # Get the bucket ($_s3->bucket would not verify that the bucket exists)
    my @buckets = $_s3_client->buckets;
    foreach my $bucket ( @buckets )
    {
        if ( $bucket->name eq $_config_bucket_name )
        {
            $_s3_bucket = $bucket;
        }
    }
    unless ( $_s3_bucket )
    {
        die "Unable to get bucket '$_config_bucket_name'.";
    }

    # Save PID
    $_pid = $$;

    my $path = ( $_config_folder_name ? "$_config_bucket_name/$_config_folder_name" : "$_config_bucket_name" );
    say STDERR "Initialized Amazon S3 download storage at '$path' for PID $$.";
}

sub _object_for_filename($)
{
    my $filename = shift;

    unless ( $filename )
    {
        die "Filename is empty.";
    }

    my $key = $_config_folder_name . $filename;
    my $object = $_s3_bucket->object( key => $key );

    return $object;
}

sub head($$)
{
    my ( $self, $filename ) = @_;

    _initialize_s3_or_die();

    my $object = _object_for_filename( $filename );
    if ( $object->exists )
    {
        return 1;
    }
    else
    {
        return 0;
    }
}

sub delete($$)
{
    my ( $self, $filename ) = @_;

    _initialize_s3_or_die();

    if (AMAZON_S3_CHECK_IF_EXISTS_BEFORE_DELETING)
    {
        unless ( $self->head( $filename ) )
        {
            die "File '$filename' does not exist.";
        }
    }

    my $object = _object_for_filename( $filename );

    $object->delete;

    return 1;
}

sub put($$$)
{
    my ( $self, $filename, $content_ref ) = @_;

    _initialize_s3_or_die();

    if ( AMAZON_S3_CHECK_IF_EXISTS_BEFORE_PUTTING )
    {
        if ( $self->head( $filename ) )
        {
            say STDERR "File '$filename' already exists, " .
              "will store a new version or overwrite (depending on whether or not versioning is enabled).";
        }
    }

    # Will die() on failure
    my $content_to_store = $$content_ref;
    my $object = _object_for_filename( $filename );
    $object->put( $content_to_store );

    return 1;
}

sub get($$)
{
    my ( $self, $filename ) = @_;

    _initialize_s3_or_die();

    if ( AMAZON_S3_CHECK_IF_EXISTS_BEFORE_GETTING )
    {
        unless ( $self->head( $filename ) )
        {
            die "File '$filename' does not exist.";
        }
    }

    # Will die() on failure
    my $object          = _object_for_filename( $filename );
    my $content = $object->get;

    return \$content;
}

sub list_iterator($;$)
{
    my ( $self, $filename_offset ) = @_;

    _initialize_s3_or_die();

    my $iterator = Storage::Iterator::AmazonS3->new(bucket => $_s3_bucket,
                                                    prefix => $_config_folder_name,
                                                    offset => $filename_offset);
    return $iterator;
}

no Moose;    # gets rid of scaffolding

1;