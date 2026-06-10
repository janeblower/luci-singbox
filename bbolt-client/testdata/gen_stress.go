//go:build ignore

// Stress-fixture generator for the Rust port's parity tests. Produces a bbolt db
// that exercises code paths the thin real cache.db does not: multiple buckets, an
// empty bucket, a small (possibly inline) bucket, a large bucket forcing B+tree
// branch pages, a value large enough to force overflow pages, a nested sub-bucket,
// and high-byte keys to test unsigned lexicographic ordering.
//
// Regenerate (from the bbolt-client/ Go module, which already requires bbolt):
//
//	go run rust/testdata/gen_stress.go rust/testdata/stress.db
package main

import (
	"fmt"
	"os"

	bolt "go.etcd.io/bbolt"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: go run gen_stress.go <out.db>")
		os.Exit(2)
	}
	path := os.Args[1]
	_ = os.Remove(path)
	db, err := bolt.Open(path, 0600, nil)
	if err != nil {
		panic(err)
	}
	defer db.Close()

	err = db.Update(func(tx *bolt.Tx) error {
		// empty bucket
		if _, e := tx.CreateBucket([]byte("a_empty")); e != nil {
			return e
		}
		// small bucket (likely stored inline)
		sb, e := tx.CreateBucket([]byte("b_small"))
		if e != nil {
			return e
		}
		_ = sb.Put([]byte("k1"), []byte("v1"))
		_ = sb.Put([]byte("k2"), []byte("value-two"))

		// big bucket: enough keys to force branch pages (tree height > 1)
		big, e := tx.CreateBucket([]byte("c_big"))
		if e != nil {
			return e
		}
		// 500 keys is enough to force a multi-level (branch) tree while keeping
		// the committed fixture small.
		for i := 0; i < 500; i++ {
			k := []byte(fmt.Sprintf("key%06d", i))
			v := []byte(fmt.Sprintf("val-%06d-padding-padding-padding-padding", i))
			if e := big.Put(k, v); e != nil {
				return e
			}
		}

		// overflow bucket: a single value larger than a page (forces page.overflow)
		ov, e := tx.CreateBucket([]byte("d_overflow"))
		if e != nil {
			return e
		}
		huge := make([]byte, 40000)
		for i := range huge {
			huge[i] = byte('A' + i%26)
		}
		_ = ov.Put([]byte("huge"), huge)
		_ = ov.Put([]byte("small"), []byte("x"))

		// nested sub-bucket: listing must show the key; Get must report "no key"
		nb, e := tx.CreateBucket([]byte("e_nested"))
		if e != nil {
			return e
		}
		_ = nb.Put([]byte("plain"), []byte("p"))
		if _, e := nb.CreateBucket([]byte("zsub")); e != nil {
			return e
		}

		// high-byte keys: unsigned lexicographic order is \x01\x02 < ~tilde < \xfe\xff
		hb, e := tx.CreateBucket([]byte("f_bytes"))
		if e != nil {
			return e
		}
		_ = hb.Put([]byte{0x01, 0x02}, []byte("low"))
		_ = hb.Put([]byte("~tilde"), []byte("tilde"))
		_ = hb.Put([]byte{0xfe, 0xff}, []byte("high"))
		return nil
	})
	if err != nil {
		panic(err)
	}
	fmt.Println("wrote", path)
}
