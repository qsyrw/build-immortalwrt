# build-immortalwrt
存放 immortalwrt _build_steps脚本

使用方法：
在根目录下执行一下命令即可


bash -c 'ROOT="$HOME"; BUILD_DIR="$ROOT/build-immortalwrt"; SRC_DIR="$ROOT/immortalwrt"; \
if [ ! -d "$BUILD_DIR/.git" ]; then git clone https://github.com/qsyrw/build-immortalwrt.git "$BUILD_DIR"; \
else (cd "$BUILD_DIR" && git pull --ff-only); fi; \
chmod +x "$BUILD_DIR/build-immortalwrt.sh"; \
bash "$BUILD_DIR/build-immortalwrt.sh" "$SRC_DIR"'
