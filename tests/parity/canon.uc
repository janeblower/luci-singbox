// tests/parity/canon.uc — recursive key-sort for order-agnostic JSON compare.
function canon(x) {
    let t = type(x);
    if (t === "object") {
        let o = {};
        for (let k in sort(keys(x))) o[k] = canon(x[k]);
        return o;
    }
    if (t === "array") {
        let a = [];
        for (let e in x) push(a, canon(e));
        return a;
    }
    return x;
}
return { canon };
