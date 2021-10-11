
### BackUP functionality
- [ ] validate_prune_backups
- [ ] prune_backups 


### internal features
content_hash_to_string

### Supported contents

sub valid_content_types 
List of supported content types:
- [x] images
- [x] rootdir
- [ ] vztmpl
- [ ] iso
- [ ] backup
- [ ] snippets
- [ ] none

Content type 2:
- [x] images
- [x] rootdir
  

## Features

### Volume managment
[+] clone_image
[+] alloc_image
[+] volume_size_info

[+] volume_resize
[+] volume_snapshot
[+] volume_rollback_is_possible
[+] volume_snapshot_rollback
[+] volume_snapshot_delete
[ ] volume_snapshot_needs_fsfreeze
sub storage_can_replicate {
sub volume_has_feature {

[ ] get_subdir -  allows to get
    get_iso_dir
    get_vztmpl_dir
    get_backup_dir


### List images
[+]list_images
<-default_format 


[+] parse_config

Methods used during addition, update and deletion of storage
[ ] on_add_hook
[ ] on_update_hook
[ ] on_delete_hook

? verify_path
? verify_server

[+] filesystem_path
[+] path

## Importing
Used by plugin implementation

[+] volume_export
[+] volume_export_formats
[+] volume_import
[+] volume_import_formats

sub find_free_diskname {


[ ] parse_lvm_name  - used from plugin
[ ] verify_portal - used from plugin
[ ] verify_portal_dns - used from plugin

verify_content
verify_format
verify_options

? parse_volume_id {
? parse_volname 

? private

? parse_section_header

? decode_value
? encode_value

## Internal
[+] filesystem_path ???
[+] path

get_vm_disk_number - used from plugin 


sub cluster_lock_storage {
sub parse_name_dir {
    if ($name =~ m!^((base-)?[^/\s]+\.(raw|qcow2|vmdk|subvol))$!) {

my $vtype_subdirs = {
sub get_vtype_subdirs {


sub create_base {

    if ($valid->{subvol}) {
sub get_next_vm_diskname {

    if ($fmt eq 'subvol') {
sub free_image {
    if (defined($format) && ($format eq 'subvol')) {
sub file_size_info {
	    outfunc => sub { $json .= shift },
	    errfunc => sub { warn "$_[0]\n" }
sub get_volume_notes {
sub update_volume_notes {

	template => { current => {qcow2 => 1, raw => 1, vmdk => 1, subvol => 1} },

my $get_subdir_files = sub {
sub list_volumes {
sub status {
sub volume_snapshot_list {
sub activate_storage {
    if (! PVE::Tools::run_fork_with_timeout($timeout, sub {-d $path})) {
	foreach my $vtype (keys %$vtype_subdirs) {
sub deactivate_storage {
sub map_volume {
sub unmap_volume {
sub activate_volume {
sub deactivate_volume {
sub check_connection {

    $logfunc //= sub { print "$_[1]\n" };
sub write_common_header($$) {
sub read_common_header($) {

