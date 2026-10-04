/**
 * [anywhere-mobile] 手机互通版本号
 * ------------------------------------------------------------
 * CI 会按仓库根的 version.json 重写这里的值（见
 * .github/workflows/build-desktop-relay.yml 的 "注入版本号" 步骤）。
 * 本地构建时不会自动重写，所以本地打包前请手动把下面的值改成当前版本，
 * 否则电脑端会向手机上报旧版本号。
 */
export const RELAY_VERSION = '1.7.0';
export const RELAY_VERSION_CODE = 20;