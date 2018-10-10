package ftdc

import (
	"bufio"
	"bytes"
	"compress/zlib"
	"context"
	"encoding/binary"
	"io"

	"github.com/mongodb/mongo-go-driver/bson"
	"github.com/pkg/errors"
)

func readDiagnostic(ctx context.Context, f io.Reader, ch chan<- *bson.Document) error {
	defer close(ch)
	buf := bufio.NewReader(f)
	for {
		doc, err := readBufBSON(buf)
		if err != nil {
			if err == io.EOF {
				err = nil
			}
			return err
		}
		select {
		case ch <- doc:
			continue
		case <-ctx.Done():
			return nil
		}
	}
}

func readChunks(ctx context.Context, ch <-chan *bson.Document, o chan<- Chunk) error {
	defer close(o)

	var metadata *bson.Document

	for doc := range ch {
		// the FTDC streams typically have onetime-per-file
		// metadata that includes information that doesn't
		// change (like process parameters, and machine
		// info. This implementation entirely ignores that.)
		docType := doc.Lookup("type")

		if isNum(0, docType) {
			metadata = doc
			continue
		} else if !isNum(1, docType) {
			continue
		}

		// get the data field which holds the metrics chunk
		zelem := doc.LookupElement("data")
		if zelem == nil {
			return errors.New("data is not populated")
		}
		_, zBytes := zelem.Value().Binary()

		// the metrics chunk, after the first 4 bytes, is zlib
		// compressed, so we make a reader for that. data
		z, err := zlib.NewReader(bytes.NewBuffer(zBytes[4:]))
		if err != nil {
			return errors.Wrap(err, "problem building zlib reader")
		}
		buf := bufio.NewReader(z)

		// the metrics chunk, which is *not* bson, first
		// contains a bson document which begins the
		// sample. This has the field and we use use it to
		// create a slice of Metrics for each series. The
		// deltas are not populated.
		metrics, err := readBufMetrics(buf)
		if err != nil {
			return errors.Wrap(err, "problem reading metrics")
		}

		// now go back and read the first few bytes
		// (uncompressed) which tell us how many metrics are
		// in each sample (e.g. the fields in the document)
		// and how many events are collected in each series.
		bl := make([]byte, 8)
		_, err = io.ReadAtLeast(buf, bl, 8)
		if err != nil {
			return err
		}
		nmetrics := int(binary.LittleEndian.Uint32(bl[:4]))
		ndeltas := int(binary.LittleEndian.Uint32(bl[4:]))

		// if the number of metrics that we see from the
		// source document (metrics) and the number the file
		// reports don't equal, it's probably corrupt.
		if nmetrics != len(metrics) {
			return errors.Errorf("metrics mismatch, file likely corrupt Expected %d, got %d", nmetrics, len(metrics))
		}

		decoder := NewDecoder(ndeltas, buf)
		// now go back and populate the delta numbers
		for i, v := range metrics {
			metrics[i].startingValue = v.startingValue
			metrics[i].Values, err = decoder.Decode()
			if err != nil {
				return err
			}

			metrics[i].Values = append([]int64{v.startingValue}, undelta(v.startingValue, metrics[i].Values)...)
			if len(metrics[i].Values)-1 != ndeltas {
				return errors.New("decoding error or data corruption")
			}
		}
		select {
		case o <- Chunk{
			metrics:  metrics,
			nPoints:  ndeltas,
			metadata: metadata,
		}:
		case <-ctx.Done():
			return nil
		}
	}
	return nil
}

func readBufDoc(buf *bufio.Reader, d interface{}) (err error) {
	var bl []byte
	bl, err = buf.Peek(4)
	if err != nil {
		return
	}
	l := int(binary.LittleEndian.Uint32(bl))

	b := make([]byte, l)
	_, err = io.ReadAtLeast(buf, b, l)
	if err != nil {
		return
	}
	err = bson.Unmarshal(b, d)
	return
}

func readBufBSON(buf *bufio.Reader) (*bson.Document, error) {
	doc := &bson.Document{}

	if err := readBufDoc(buf, doc); err != nil {
		return nil, err
	}

	return doc, nil
}

func readBufMetrics(buf *bufio.Reader) (metrics []Metric, err error) {
	doc := &bson.Document{}
	err = readBufDoc(buf, doc)
	if err != nil {
		return
	}
	metrics = flattenDocument([]string{}, doc)
	return
}