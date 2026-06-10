//go:build ignore

// Crafted-malformed bbolt db generator for regression-testing the Rust port's
// corruption guards. These structures cannot be produced through the bbolt API
// (cyclic page links, a wrapping pgid, a bogus overflow field), so the pages are
// written by hand. Layout: pageSize 4096; meta0/meta1 -> root bucket on page 3;
// page 3 holds one sub-bucket "x" pointing at page 4, which the variants corrupt.
//
//	go run rust/testdata/gen_corrupt.go <cyclic|wrap|overflow> <out.db>
package main

import (
	"encoding/binary"
	"hash/fnv"
	"os"
)

const ps = 4096

func meta(buf []byte, page int, root uint64) {
	off := page * ps
	binary.LittleEndian.PutUint64(buf[off:], uint64(page)) // page id
	binary.LittleEndian.PutUint16(buf[off+8:], 0x04)       // meta flag
	m := off + 16
	binary.LittleEndian.PutUint32(buf[m:], 0xED0CDAED) // magic
	binary.LittleEndian.PutUint32(buf[m+4:], 2)        // version
	binary.LittleEndian.PutUint32(buf[m+8:], ps)       // pageSize
	binary.LittleEndian.PutUint64(buf[m+16:], root)    // root.root
	binary.LittleEndian.PutUint64(buf[m+32:], 2)       // freelist pgid
	binary.LittleEndian.PutUint64(buf[m+40:], 6)       // high-water pgid (== page count)
	binary.LittleEndian.PutUint64(buf[m+48:], 10)      // txid
	h := fnv.New64a()
	_, _ = h.Write(buf[m : m+56])
	binary.LittleEndian.PutUint64(buf[m+56:], h.Sum64())
}

func hdr(buf []byte, id uint64, flags, count uint16, overflow uint32) {
	o := int(id) * ps
	binary.LittleEndian.PutUint64(buf[o:], id)
	binary.LittleEndian.PutUint16(buf[o+8:], flags)
	binary.LittleEndian.PutUint16(buf[o+10:], count)
	binary.LittleEndian.PutUint32(buf[o+12:], overflow)
}

// leaf root-bucket page: one sub-bucket entry key -> bucket{root: subRoot}
func rootBucketPage(buf []byte, id uint64, key byte, subRoot uint64) {
	hdr(buf, id, 0x02, 1, 0)
	o := int(id)*ps + 16
	binary.LittleEndian.PutUint32(buf[o:], 0x01)  // leaf flags: bucketLeafFlag
	binary.LittleEndian.PutUint32(buf[o+4:], 16)  // pos (key at o+16)
	binary.LittleEndian.PutUint32(buf[o+8:], 1)   // ksize
	binary.LittleEndian.PutUint32(buf[o+12:], 16) // vsize (bucket header)
	buf[o+16] = key
	binary.LittleEndian.PutUint64(buf[o+17:], subRoot) // bucket.root
	binary.LittleEndian.PutUint64(buf[o+25:], 0)       // bucket.sequence
}

// branch page with one element pointing at child
func branchPage(buf []byte, id, child uint64) {
	hdr(buf, id, 0x01, 1, 0)
	o := int(id)*ps + 16
	binary.LittleEndian.PutUint32(buf[o:], 16)  // pos
	binary.LittleEndian.PutUint32(buf[o+4:], 1) // ksize
	binary.LittleEndian.PutUint64(buf[o+8:], child)
	buf[o+16] = 'k'
}

// leaf page with one plain key->value and a (possibly bogus) overflow field
func leafPage(buf []byte, id uint64, overflow uint32, key, val byte) {
	hdr(buf, id, 0x02, 1, overflow)
	o := int(id)*ps + 16
	binary.LittleEndian.PutUint32(buf[o:], 0)    // leaf flags: plain key
	binary.LittleEndian.PutUint32(buf[o+4:], 16) // pos
	binary.LittleEndian.PutUint32(buf[o+8:], 1)  // ksize
	binary.LittleEndian.PutUint32(buf[o+12:], 1) // vsize
	buf[o+16] = key
	buf[o+17] = val
}

func main() {
	if len(os.Args) < 3 {
		os.Stderr.WriteString("usage: go run gen_corrupt.go <cyclic|wrap|overflow> <out.db>\n")
		os.Exit(2)
	}
	kind, path := os.Args[1], os.Args[2]
	buf := make([]byte, 6*ps)
	meta(buf, 0, 3)
	meta(buf, 1, 3)
	// page 2 (freelist) left zero — a read-only reader never touches it.
	switch kind {
	case "cyclic":
		rootBucketPage(buf, 3, 'x', 4)
		branchPage(buf, 4, 5)
		branchPage(buf, 5, 4) // 4 <-> 5 cycle
	case "wrap":
		rootBucketPage(buf, 3, 'x', 4)
		branchPage(buf, 4, 0x10000000000003) // *4096 wraps mod 2^64 to page 3
	case "overflow":
		rootBucketPage(buf, 3, 'x', 4)
		leafPage(buf, 4, 0xFFFF, 'q', 'v') // valid leaf, bogus huge overflow
	default:
		os.Stderr.WriteString("unknown kind: " + kind + "\n")
		os.Exit(2)
	}
	if err := os.WriteFile(path, buf, 0644); err != nil {
		panic(err)
	}
}
