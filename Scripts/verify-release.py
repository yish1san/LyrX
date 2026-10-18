#!/usr/bin/env python3
"""检查实际发布包，错误时停止打包；不显示命中的敏感内容。"""
import plistlib
import re
import sys
from pathlib import Path

app = Path(sys.argv[1])
allowed = {
    "Contents/Info.plist", "Contents/MacOS/LyrX",
    "Contents/Resources/AppIcon.icns", "Contents/Resources/LICENSE",
    "Contents/_CodeSignature/CodeResources",
}
checks = {
    "本机用户或临时目录": rb"/(?:Users/|private/var/folders/|var/folders/)",
    "已移除的酷狗接口": rb"kugou\.com",
    "私钥": rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
    "常见访问令牌": rb"(?:AKIA|ASIA)[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9]{30,}|sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{40,}",
}
errors = []
for path in app.rglob("*"):
    if path.is_symlink():
        errors.append("应用内含未预期的符号链接")
        continue
    if not path.is_file():
        continue
    name = path.relative_to(app).as_posix()
    if name not in allowed:
        errors.append("应用内含未预期的文件")
    data = path.read_bytes()
    for label, pattern in checks.items():
        if re.search(pattern, data):
            errors.append(label)
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
if "NSAppTransportSecurity" in info:
    errors.append("发布配置仍含传输安全例外")
if info.get("CFBundleName") != "LyrX" or info.get("CFBundleIdentifier") != "com.local.lyrx":
    errors.append("应用身份不匹配")
if errors:
    print("发布隐私检查失败：" + "、".join(sorted(set(errors))), file=sys.stderr)
    sys.exit(1)
print("发布隐私检查通过：未检出本机路径、常见令牌、额外文件或酷狗接口。")
