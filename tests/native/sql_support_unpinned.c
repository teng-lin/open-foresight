/* Deliberately has no retained image reference: native loader negative control.
 */
__attribute__((visibility("default"))) int fs_sql_unpinned_fixture(void) {
  return 1;
}
