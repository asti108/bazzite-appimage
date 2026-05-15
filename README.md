## Usage

1. Download either the `.zip` archive or the `.sh` script directly.
2. If you downloaded the `.zip` archive, extract it and locate the `deb2appimage.sh` script.
3. Open a terminal app and make the script executable:

```bash
chmod +x /path/to/deb2appimage.sh
```

4. Navigate to the directory containing the script:

```bash
cd /path/to/
```

5. Run the script using the following syntax:

```bash
./deb2appimage.sh /path/to/package.deb /path/to/output-directory
```

### Example

```bash
./deb2appimage.sh ~/Downloads/example-package.deb ~/AppImages
```

The generated AppImage will be placed in the output directory you specify.

That's all, enjoy!
