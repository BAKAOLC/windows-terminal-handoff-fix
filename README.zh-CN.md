# Windows Terminal Handoff Fix

[English](README.md) | **简体中文**

Windows Terminal Handoff Fix 修复两类导致 Windows 回退到传统控制台宿主的问题：GUI 应用分配控制台时未触发默认终端接管，以及提权进程的 COM 激活失败。

| 组件              | 用途                                                                                                     |
| ----------------- | -------------------------------------------------------------------------------------------------------- |
| Windhawk mod      | 修正 GUI 应用控制台连接请求中的 `ConsoleApp` 标记，使 Windows 能够继续判断请求是否满足默认终端接管条件。 |
| Terminal 部署脚本 | 安装微软官方非打包版 Windows Terminal，并在机器级注册 x86 和 x64 COM 服务与代理。                        |

两个组件可以独立使用。mod 作用于 Windhawk 能够注入的应用，无需为应用配置专用启动器，也不替换 Windows 系统文件。

## 环境要求

- Windows 11 x64，且已将 Windows Terminal 设为默认终端应用。
- Windhawk 1.7 或更新版本，采用标准的注册表存储布局，并包含自带的编译器和导入库。
- 运行脚本需要 64 位 PowerShell 7.4 或更新版本。
- 安装、更新、卸载、启用或停用组件需要管理员权限。

可选的 Terminal 部署从微软 GitHub Releases 下载最新正式版。下载文件会根据 GitHub 提供的 SHA-256 摘要进行校验，可执行文件和 COM 代理还会检查微软数字签名。

## 安装

在项目目录中打开管理员 PowerShell 7，构建并安装 mod：

```powershell
./scripts/Build-Mod.ps1
./scripts/Manage-Mod.ps1 -Action Install
```

mod 沿用已有默认终端，不修改终端配置。重启需要修复的应用，可确保 mod 在应用分配控制台前加载。已打开的控制台不会迁移。

### 应用例外

Windhawk 的全局排除规则仍然有效。如需在安装时为指定应用添加例外，将 mod 安装命令替换为：

```powershell
./scripts/Manage-Mod.ps1 -Action Install -IncludeApplication 'C:\Applications\Example\Example.exe'
```

可执行文件必须存在。脚本为指定路径添加例外，并将该应用加入其他匹配 mod 的排除列表，防止其他 mod 通过同一例外注入应用。`-IncludeApplication` 仅用于安装，不修改已安装的 mod。

### 可选：修复提权 COM 激活

如果提权应用无法激活打包版 Terminal，可安装非打包版并配置机器级 COM 注册：

```powershell
./scripts/Manage-Terminal.ps1 -Action Install -RemoveStore -ContextMenu
```

程序文件安装在 `C:\Program Files\Windows Terminal\app`。使用 `-InstallPath` 可指定其他安装根目录，程序文件放在其 `app` 子目录中。安装根目录必须尚不存在；脚本不会接管其他工具管理的安装。

`-RemoveStore` 移除运行脚本的账户所安装的打包版 Terminal，并在移除前保存对应的官方安装包以供恢复。其他账户不受影响。省略该选项时，打包版会继续保留，非提权进程仍可能优先使用它。已有非打包版配置会保留；仅当目标配置目录为空时，才复制打包版的配置和 Fragments。

`-ContextMenu` 为文件夹、文件夹空白处和磁盘添加传统的“Open in Terminal”菜单，在 Windows 11 中位于“显示更多选项”下。非打包版不包含商店更新机制，也不提供打包版的现代右键菜单扩展，详见[Windows Terminal 发行方式](https://learn.microsoft.com/windows/terminal/distributions)。

## 工作原理

### GUI 控制台分配

Windows 会先判断控制台连接是否满足接管条件，再激活默认终端。GUI 应用调用 `AllocConsole()` 时，发送给 ConDrv 的连接请求可能将 `ConsoleApp` 设为假。控制台宿主的 [`_shouldAttemptHandoff`](https://github.com/microsoft/terminal/blob/main/src/server/IoDispatchers.cpp) 会在尝试激活终端前拒绝这类请求。

mod 钩住导出的 `AllocConsole` API，以及可用时的 `AllocConsoleWithOptions`。在控制台分配调用期间，mod 检查发往 ConDrv 的 `NtCreateFile` 请求，并按照 Windows Terminal 仓库公开的[控制台连接结构](https://github.com/microsoft/terminal/blob/main/dep/Console/conmsgl1.h) 解析扩展属性。

修改前，解析器会校验设备路径或父设备、EA 名称和链表边界、负载大小、布尔字段及 UTF-16 字符串边界。符合条件的 `server` 请求会复制后修正，再传给系统；调用方的原始缓冲区不变。附加请求、隐藏或最小化窗口请求，以及无法识别的消息保持原样。Windows 仍会检查其余接管条件。

函数地址在运行时通过导出表解析，不依赖私有函数偏移、指令特征、系统 DLL 哈希或符号下载。`AllocConsoleWithOptions` 从 Windows 11 24H2 起提供，因此是可选入口；更早版本使用 `AllocConsole`。DLL 地址变化不需要更新偏移，但 ConDrv 协议发生不兼容变化时，解析器可能需要调整。

### 控制台窗口可见性

应用可能先分配控制台，再将它隐藏用于后台工作。在 ConPTY 下，`GetConsoleWindow()` 返回的是伪窗口，而不是可见的 Terminal 窗口。Terminal 原生的可见性转发会将相关操作转为最小化和还原，无法保留 `SW_HIDE` 的隐藏行为。

对于通过 mod 分配的控制台，`ShowWindow`、`ShowWindowAsync` 和 `SetWindowPos` 的可见性标志会转发到所属的 Terminal 窗口，`IsWindowVisible` 则返回该窗口的可见性。目标通过伪窗口的所有者关系确定，不依赖窗口标题、前台焦点、程序名称或安装路径。隐藏期间控制台保持连接。

应用立即发出隐藏请求时，Terminal 的最后一次启动显示操作可能尚未完成。进程内的事件监听会在这个初始化竞态中保留隐藏请求，只监听关联的 Terminal 进程，并在操作前重新核实窗口归属。mod 卸载时会释放事件钩子和工作线程；应用后续发出的显示请求会取消待处理的隐藏状态。

如果同一 Terminal 窗口拥有多个伪控制台窗口，mod 会保留原生行为，避免隐藏无关会话。其他窗口、已有控制台及无法识别的终端宿主也保持原生行为。可见性转发并不模拟传统控制台的全部窗口管理 API。

### 提权 COM 激活

接管过程还依赖 COM 激活。如果提权进程无法发现打包版 Terminal 的 COM 服务，激活可能返回 `REGDB_E_CLASSNOTREG`（`0x80040154`），使系统回退到传统宿主。[microsoft/terminal#10276](https://github.com/microsoft/terminal/issues/10276) 讨论了这一限制，是否受影响取决于 Windows 版本和安装方式。

可选部署脚本在机器级注册非打包版 Terminal 的 x86 和 x64 COM 服务与代理，用于处理激活失败。该修复与 mod 对 GUI 控制台请求的修正相互独立。

## 维护

查看或切换 mod 状态：

```powershell
./scripts/Manage-Mod.ps1 -Action Status
./scripts/Manage-Mod.ps1 -Action Disable
./scripts/Manage-Mod.ps1 -Action Enable
```

安装 mod 或切换其状态会重启 Windhawk 服务。

对于通过部署脚本安装的 Terminal：

```powershell
./scripts/Manage-Terminal.ps1 -Action Status
./scripts/Manage-Terminal.ps1 -Action Update
./scripts/Manage-Terminal.ps1 -Action Repair
```

更新前，关闭使用该 Terminal 安装的所有会话，并从其他控制台宿主运行更新脚本。更新保留安装路径和用户配置；失败时尝试恢复上一版本，成功后清理旧程序文件和临时下载文件。`Repair` 重新应用 COM 注册及其他已记录的集成设置。更新需手动执行。

修改命令支持使用 `-WhatIf` 预览操作，不应用变更，也不请求提权：

```powershell
./scripts/Manage-Mod.ps1 -Action Install -WhatIf
./scripts/Manage-Terminal.ps1 -Action Install -RemoveStore -WhatIf
```

## 卸载与恢复

卸载 mod：

```powershell
./scripts/Manage-Mod.ps1 -Action Uninstall
```

卸载通过部署脚本安装的 Terminal：

```powershell
./scripts/Manage-Terminal.ps1 -Action Uninstall
```

mod 卸载根据安装记录识别需要移除的库和应用例外。Terminal 卸载恢复安装记录中的注册表原值，并移除安装脚本添加的 PATH 项；被单独修改过的注册表值会保留。如果安装时移除了打包版 Terminal，卸载时会使用保存的官方安装包恢复，并将终端配置复制回打包版。非打包版的用户配置目录会保留。

安装记录和恢复包保存在 `%PROGRAMDATA%\WindowsTerminalHandoffFix` 下。使用 `-StateRoot` 可指定其他状态目录，维护和卸载时须使用相同路径，并在安装时使用的 Windows 账户下执行。卸载完成前应保留安装记录和恢复包。

临时目录删除仅限脚本创建且通过归属校验的目录，不经过回收站。如果自动回退失败，脚本会返回错误并保留恢复状态。

## 限制

- mod 支持 x86 和 x64 应用。部署脚本不支持原生 ARM64 应用和 Windhawk 便携式存储布局。
- 服务、非交互会话，以及隐藏或最小化控制台请求保持原有行为。
- 受保护进程、被全局排除的应用，以及 Windhawk 无法注入的应用，仍可能使用传统宿主。
- Windows 的接管检查仍然有效，包括显式禁用接管的请求；系统的兼容性回退机制保留。
- 机器级 COM 注册不修改所有账户的默认终端偏好。默认终端选择和配置迁移仅针对运行脚本的账户。

## 许可证

源码和脚本使用 [MIT License](LICENSE)。Windows Terminal、Windhawk 及其工具链遵循各自许可证。项目不包含微软程序或 Windhawk 运行库。
