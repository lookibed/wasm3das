options gen2
options indenting = 4

require math
require dastest/testing_boost public

// A program that overloads a builtin math name for its own type has to spell the
// builtin one with its module qualifier ("math::sqrt") to say which of the two it
// means. That spelling has to behave exactly like the unqualified one in every
// tier. The arguments below all come from runtime data, so nothing is constant
// folded away before the backend sees the call.

struct Vec2 {
    x : float
    y : float
}

// our own sqrt, over Vec2 - this is why every builtin call below is qualified
def sqrt(v : Vec2) : Vec2 {
    return Vec2(x = math::sqrt(v.x), y = math::sqrt(v.y))
}

def vec_length(v : Vec2) : float {
    return math::sqrt(v.x * v.x + v.y * v.y)
}

def grid_cell(v : Vec2; cell : float) : int2 {
    return int2(math::floori(v.x / cell), math::floori(v.y / cell))
}

def unit_scale(v : Vec2) : float {
    return math::exp(math::log(vec_length(v)))
}

def make_points(n : int) : array<Vec2> {
    var pts : array<Vec2>
    for (i in range(1, n + 1)) {
        pts |> push(Vec2(x = float(3 * i), y = float(4 * i)))
    }
    return <- pts
}

[test]
def test_qualified_sqrt_on_runtime_data(t : T?) {
    var pts <- make_points(4)
    for (i in range(0, length(pts))) {
        // 3-4-5 triangles: |(3k, 4k)| == 5k
        t |> success(abs(vec_length(pts[i]) - float(5 * (i + 1))) < 1.0e-4f,
            "math::sqrt on element {i}")
    }
}

[test]
def test_qualified_sqrt_matches_unqualified(t : T?) {
    var pts <- make_points(4)
    for (p in pts) {
        let d = p.x * p.x + p.y * p.y
        t |> success(math::sqrt(d) == sqrt(d), "math::sqrt(d) == sqrt(d) for d = {d}")
    }
}

[test]
def test_qualified_sqrt_of_own_overload(t : T?) {
    var pts <- make_points(1)
    let s = sqrt(Vec2(x = pts[0].x * pts[0].x, y = pts[0].y * pts[0].y))
    t |> success(abs(s.x - 3.0f) < 1.0e-4f, "own sqrt(Vec2).x")
    t |> success(abs(s.y - 4.0f) < 1.0e-4f, "own sqrt(Vec2).y")
}

[test]
def test_qualified_floori_and_exp_log(t : T?) {
    var pts <- make_points(2)
    t |> equal(grid_cell(pts[0], 2.0f), int2(1, 2), "math::floori on runtime data")
    t |> equal(grid_cell(pts[1], 2.0f), int2(3, 4), "math::floori on runtime data")
    t |> success(abs(unit_scale(pts[0]) - 5.0f) < 1.0e-3f, "math::exp(math::log(x)) == x")
}
