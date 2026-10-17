# Workspace rules

All task-generated temporary files must be stored under `/Volumes/4TB_Drive/tmp/` in a task-specific directory. This includes debug journals, scratch scripts, logs, screenshots, test fixtures, downloads, temporary transfer files, and build output created for a task.

Set `TMPDIR=/Volumes/4TB_Drive/tmp/` for commands and tools that choose their own temporary directory. Configure explicit output paths when available. Do not create task scratch files in the workspace or system temporary directories. Move or remove owned artifacts created elsewhere, and keep their references consistent with the required location.
