/* ============================================================================
   部署配置 —— 上线前只需要改这一个文件
   1) apkUrl：APK 地址。
      · 放自己服务器：文件丢进 Rpage/download/，保持 "download/shuaqi-0.1.2.apk"
      · 走 GitHub Releases：填 assets 直链（默认已填好，建完 Release 即生效）
   2) github：填了才会显示「GitHub 仓库」按钮。
   ========================================================================= */
window.SHUAQI = {
  apkUrl: "https://github.com/Terryliu001/SHUA_QI/releases/download/v0.1.2/shuaqi-0.1.2.apk",
  github: "https://github.com/Terryliu001/SHUA_QI"
};
