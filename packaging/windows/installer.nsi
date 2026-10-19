; YuanLian 0.2.0 per-user installer. Build with makensis (NSIS 3.11).
; Required defines: VERSION, STAGE, OUTFILE.
Unicode true
!include "MUI2.nsh"
!include "FileFunc.nsh"

!ifndef VERSION
  !define VERSION "0.2.0"
!endif
!ifndef STAGE
  !error "STAGE must point to the staging/YuanLian directory"
!endif
!ifndef OUTFILE
  !define OUTFILE "YuanLian-${VERSION}-windows-x64-setup.exe"
!endif

Name "YuanLian"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\YuanLian"
InstallDirRegKey HKCU "Software\YuanLian" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
BrandingText "YuanLian ${VERSION}"

Function .onInit
  SetShellVarContext current
FunctionEnd

VIProductVersion "0.2.0.2"
VIAddVersionKey /LANG=2052 "ProductName" "YuanLian"
VIAddVersionKey /LANG=2052 "FileDescription" "YuanLian remote desktop installer"
VIAddVersionKey /LANG=2052 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "AGPL-3.0-or-later"

!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "安装 YuanLian ${VERSION}"
!define MUI_WELCOMEPAGE_TEXT "YuanLian 是远控客户端与被控 Host 的工具集。$\r$\n$\r$\n本安装器按当前用户安装到 LocalAppData，不需要管理员权限，也不会自动开启被控、无人值守或修改防火墙。"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\client\yuanlian_client.exe"
!define MUI_FINISHPAGE_RUN_TEXT "启动远联主控"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "主控客户端（必需）" SEC_CLIENT
  SectionIn RO
  SetOutPath "$INSTDIR\client"
  File /r "${STAGE}\client\*.*"
  SetOutPath "$INSTDIR"
  File "${STAGE}\LICENSE"
  File "${STAGE}\THIRD_PARTY.md"
  File "${STAGE}\VERSION.txt"
SectionEnd

Section "被控 Host 与诊断查看器（可选）" SEC_TOOLS
  SetOutPath "$INSTDIR\bin"
  File "${STAGE}\bin\yl-host.exe"
  File "${STAGE}\bin\yl-viewer.exe"
  SetOutPath "$INSTDIR"
SectionEnd

Section "文档" SEC_DOCS
  SetOutPath "$INSTDIR\docs"
  File /r "${STAGE}\docs\*.*"
  SetOutPath "$INSTDIR"
SectionEnd

Section "开始菜单快捷方式" SEC_SHORTCUTS
  CreateDirectory "$SMPROGRAMS\YuanLian"
  CreateShortcut "$SMPROGRAMS\YuanLian\远联主控.lnk" "$INSTDIR\client\yuanlian_client.exe"
  CreateShortcut "$SMPROGRAMS\YuanLian\卸载远联.lnk" "$INSTDIR\uninstall.exe"
SectionEnd

Section "系统启动时启动主控（可选）" SEC_STARTUP
  CreateShortcut "$SMSTARTUP\远联主控.lnk" "$INSTDIR\client\yuanlian_client.exe"
SectionEnd

Section "Uninstall"
  Delete "$SMSTARTUP\远联主控.lnk"
  Delete "$SMPROGRAMS\YuanLian\远联主控.lnk"
  Delete "$SMPROGRAMS\YuanLian\卸载远联.lnk"
  RMDir "$SMPROGRAMS\YuanLian"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\YuanLian"
  DeleteRegKey HKCU "Software\YuanLian"
  RMDir /r "$INSTDIR\client"
  RMDir /r "$INSTDIR\bin"
  RMDir /r "$INSTDIR\docs"
  RMDir /r "$INSTDIR\quality-preview"
  Delete "$INSTDIR\LICENSE"
  Delete "$INSTDIR\THIRD_PARTY.md"
  Delete "$INSTDIR\VERSION.txt"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  IfSilent keep_data
  MessageBox MB_YESNO|MB_ICONQUESTION "是否删除设备身份（$LOCALAPPDATA\YuanLian）以及登录令牌/用户配置（$APPDATA\YuanLian）？$\r$\n选择“否”会保留，便于重新安装后继续配对。" IDYES delete_data IDNO keep_data
  delete_data:
    RMDir /r "$LOCALAPPDATA\YuanLian"
    RMDir /r "$APPDATA\YuanLian"
    Goto done
  keep_data:
    DetailPrint "已保留用户身份与配置"
  done:
SectionEnd

Function .onInstSuccess
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "Software\YuanLian" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\YuanLian" "DisplayName" "YuanLian"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\YuanLian" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\YuanLian" "Publisher" "YuanLian"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\YuanLian" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\YuanLian" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\YuanLian" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\YuanLian" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\YuanLian" "EstimatedSize" "$0"
FunctionEnd

LangString DESC_SEC_CLIENT ${LANG_SIMPCHINESE} "Flutter 主控客户端及其运行库。"
LangString DESC_SEC_TOOLS ${LANG_SIMPCHINESE} "yl-host 被控端与 yl-viewer 诊断查看器；安装不会自动启动或放开端口。"
LangString DESC_SEC_DOCS ${LANG_SIMPCHINESE} "安装、发布说明、已知问题和许可证。"
LangString DESC_SEC_SHORTCUTS ${LANG_SIMPCHINESE} "创建开始菜单快捷方式。"
LangString DESC_SEC_STARTUP ${LANG_SIMPCHINESE} "登录 Windows 时启动主控客户端；默认不勾选。"

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_CLIENT} $(DESC_SEC_CLIENT)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_TOOLS} $(DESC_SEC_TOOLS)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_DOCS} $(DESC_SEC_DOCS)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_SHORTCUTS} $(DESC_SEC_SHORTCUTS)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_STARTUP} $(DESC_SEC_STARTUP)
!insertmacro MUI_FUNCTION_DESCRIPTION_END
