// [cannon][A17][2026-11-21]
// 空实现。这个库唯一的作用是给 cannon_vendor_src_deps 提供一个可链接的
// 目标，从而在 Soong 里建立到 vendor_available 库的 sharedLibDepTag 依赖。
// 依赖一旦建立，Soong 就会为每个依赖生成 <name>.vendor 的 Make 模块名，
// 并写进 LOCAL_REQUIRED_MODULES，Make 就会把 vendor 变体装进 /vendor。
int cannon_vendor_src_deps_anchor;
