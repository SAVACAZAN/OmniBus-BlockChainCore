# Verific dacă există deja build.zig
if [ -f build.zig ]; then
    echo "build.zig exists"
    head -100 build.zig
else
    echo "build.zig not found - need to create it"
fi