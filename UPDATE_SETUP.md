# GitHub 自动更新配置

Sub Buddy（字幕搭档）使用 Sparkle 2.9.6。App 每天自动检查一次 GitHub Releases，也可从 App 菜单或首页独立的“软件更新”区域手动检查；更新包必须通过 EdDSA 签名才会安装。

## 首次配置

1. 将项目推送到 GitHub 仓库。
2. 安装并登录 GitHub CLI：

   ```sh
   brew install gh
   gh auth login
   ```

3. 在项目目录执行以下命令。脚本会从钥匙串临时导出私钥、通过 `gh secret set` 安全上传，并立即删除临时文件；不会在终端打印私钥：

   ```sh
   zsh scripts/configure_github_updates.sh 你的用户名/仓库名
   ```

4. 打开 Actions → “Build and publish macOS update” → Run workflow，填写版本号和递增的构建号。

工作流会自动构建 Apple Silicon + Intel 的 Universal 2 DMG、注入当前 GitHub 仓库地址、签名 `appcast.xml`，并把 DMG 与 appcast 发布为 GitHub Release。无需租服务器，下载和更新流量由 GitHub Releases 提供。

## 本机发布

已安装并登录 GitHub CLI 时，也可以运行：

```sh
GITHUB_REPOSITORY=用户名/仓库名 APP_VERSION=0.6.1 APP_BUILD_NUMBER=17 zsh scripts/publish_github_release.sh
```

每次发布必须增加 `APP_BUILD_NUMBER`。已经交付给用户的 `SUPublicEDKey` 不能更换，否则旧版本会拒绝新更新。不要把导出的私钥文件、Secret 值或钥匙串内容提交到 GitHub。
