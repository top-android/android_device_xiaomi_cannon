// Intentionally trivial. This file exists only so that a vendor:true cc_library_shared
// (libnetutils_vendor_dep) has at least one source, and via its shared_libs dependency
// pulls the vendor variant of libnetutils into /vendor/lib64.
//
// Why: /vendor/bin/hw/tetheroffloadservice (A12 blob) has NEEDED libnetutils.so, but the
// A16 vendor rebuild dropped it. Without it the HAL fails to link, never registers, and
// Tethering blocks forever waiting for IOffloadConfig -> Settings ANR when enabling hotspot.
void libnetutils_vendor_dep_anchor(void) {}
