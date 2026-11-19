/*
 * [cannon][A17] 去掉 codec2 AIDL 服务的 VINTF 稳定性标记。
 *
 * 生成的 BnComponentStore 构造函数会调用 AIBinder_markVintfStability()，
 * servicemanager 因此要求该服务必须出现在 /vendor/etc/vintf/manifest.xml 里
 * 才允许注册。我们的 store 是 Magisk 模块带进来的，没法进 manifest
 * （servicemanager 在 post-fs-data 之前就把 manifest 读完了），
 * 所以这里把这个标记吞掉，注册就不再需要 VINTF 声明。
 */
struct AIBinder;

void AIBinder_markVintfStability(struct AIBinder *binder) {
    (void)binder;
}
