# Port notes

Every Mac bug fix or addition lands with a markdown file in this folder, in the same commit, on GitHub.

- `windows/YYYY-MM-DD-slug.md` for the Windows app
- `linux/YYYY-MM-DD-slug.md` once a Linux build exists

The file is for someone who has the newest Windows or Linux source and needs the same change. It is not a hotfix for a frozen exe. The Windows zip picks the change up the next time that app is built.

Copy `ports/_template.md`. Fill it in.

If the change is Mac-only (glass, the menu bar, NSEvent, a Mac framework), still add the file. Set `Applies: no` and say why in one line.

The `## Script` section is required. If the change is mechanical, put real commands there (PowerShell on Windows, a shell script on Linux). If it is a behavior change, put ordered steps an agent on that machine can apply to the Windows or Linux code.
