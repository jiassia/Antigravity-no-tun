# Antigravity-no-tun

在 Windows 上自动查找 Antigravity 和 `agy` CLI，检测本机代理并配置启动环境，无需开启 TUN。

**[下载一键启动文件](https://github.com/jiassia/Antigravity-no-tun/releases/latest/download/Antigravity-No-TUN.bat)**

下载后双击即可运行。该文件包含运行所需的脚本；下载整个仓库后，也可以双击其中的 [`一键启动.bat`](一键启动.bat)。首次运行会将程序安装到当前用户目录。安装了图形界面时，之后可以使用桌面上的 Antigravity 图标启动。

使用旧版本时，请下载最新的一键启动文件并运行一次，以更新本机脚本。

## 使用条件

- Windows 10 或 Windows 11，以及系统自带的 Windows PowerShell 5.1。
- 已安装 Antigravity，或已安装需要使用的 `agy` 命令行程序。
- 本机已有可用的代理客户端和有效配置。程序会尝试查找并启动已安装的客户端，但不会提供服务器、账户或订阅。

程序会从运行进程、快捷方式、安装目录、注册表、系统代理、代理配置和本地监听端口查找候选项。支持识别常见的 Clash 系列、v2rayN、Qv2ray、NekoRay、NekoBox、Netch、Hiddify、sing-box、Shadowsocks 等客户端。具体可识别范围取决于客户端的安装方式和本机监听设置。HTTP 或 mixed 代理会直接使用；仅提供无认证本机 SOCKS5 端口时，程序会启动本地转换服务。代理通过 HTTPS 连接验证后才会应用。

## 运行过程

1. 查找 Antigravity 和本地代理，必要时尝试启动已安装的代理客户端。
2. 记录原有设置，为当前用户配置 Windows 系统代理和 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY` 环境变量。其他使用系统代理或这些变量的程序也可能使用该代理。使用 SOCKS5 转换时，程序还会为转换服务创建当前用户的登录启动项。
3. 检测到 `agy` CLI 时，自动配置其命令路径。
4. 如果安装了图形界面，备份并更新 Antigravity 快捷方式，然后启动软件；如果只安装了 CLI，则直接启动 CLI。

当已有 Antigravity 窗口需要重启时，程序会尝试保存并核对输入草稿，再正常关闭窗口。应用接口不可用或窗口未正常退出时，程序会保留现有进程并提示原因。应用版本更新可能改变草稿接口。

## 使用 agy CLI

安装 `agy` CLI 后，双击最新的 **一键启动.bat**。脚本会自动为 CLI 配置代理和命令路径。

如果同时安装了图形界面，配置完成后请完全退出并重新打开终端，然后运行：

```text
agy
```

如果只安装了 CLI，脚本配置完成后会直接启动它。Windows Terminal 需要退出全部窗口后重新打开，才能读取新的用户环境变量。

## 恢复原设置

双击本仓库中的 `恢复原设置.bat`，或打开以下文件：

```text
%LOCALAPPDATA%\AntigravityProxyHelper\恢复原设置.bat
```

原系统代理、环境变量、快捷方式备份和运行状态保存在 `%LOCALAPPDATA%\AntigravityProxyHelper\app\backups`。恢复操作会保留配置后另行修改过的设置，并移除本程序创建的转换服务启动项。草稿副本保存在同一备份目录下，可能包含输入内容，请勿上传或分享。重新打开终端后，恢复的环境变量才会生效。

## 检查与常见问题

- 双击 `检查代理.bat` 可以检查软件位置和代理连通性，不修改用户代理设置。
- 找不到代理时，请确认代理客户端已经安装、配置有效并提供本机 HTTP、mixed 或无认证 SOCKS5 端口。仅有系统级 TUN 或需要认证的代理端口不能保证自动适配。
- 代理可连接不代表服务账号或所在地区一定满足 Antigravity 的使用条件。
- 运行日志和备份只保存在本机；不要将 `backups`、`diagnostics`、运行状态或自定义 `proxy-config.json` 上传到公开仓库。

## 源码与构建

仓库包含可直接查看的 PowerShell、C# 和 JavaScript 源码。修改源码后，在本目录运行 `powershell -NoProfile -ExecutionPolicy Bypass -File .\build-single-file.ps1`，即可重新生成包含最新源码的 `一键启动.bat`。运行程序不需要安装 Node.js、Python 或额外的 PowerShell 模块。

Community: [LINUX DO](https://linux.do/)
