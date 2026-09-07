options gen2
options indenting = 4
require math

// Non-foldable module-qualified call of a math intrinsic: the argument is read
// from a mutable global, so the compiler cannot constant-fold the call away.
var g_x = 9.0

[export]
def main() {
    print("qualified sqrt = {math::sqrt(g_x)}\n")
}
