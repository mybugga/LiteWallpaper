#pragma once
// Release builds pass the version in (build.bat 1.2.3). Local builds are "dev" and never update themselves.
#ifndef LW_VERSION
#define LW_VERSION "dev"
#endif

// GitHub repository the updater takes releases from.
#define LW_REPO "mybugga/LiteWallpaper"

// Inno Setup's uninstall key for installer/LiteWallpaper.iss (its AppId plus "_is1"). The updater
// keeps the version shown in Settings > Apps right when it updates an installed copy.
#define LW_UNINSTALL_KEY L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{E3EC2D51-2006-420E-9556-FA3118C3D5EF}_is1"
