// syncophant-crypt delegates all cryptography and format handling to rclone.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"

	"github.com/rclone/rclone/backend/crypt"
	"github.com/rclone/rclone/fs/config/configmap"
	"github.com/rclone/rclone/fs/config/obscure"
)

const maximumMessage = 48 * 1024 * 1024

type request struct {
	Op        string `json:"op"`
	Password  string `json:"password"`
	Password2 string `json:"password2"`
	Path      string `json:"path"`
	Data      []byte `json:"data"`
	Offset    int64  `json:"offset"`
	Length    int64  `json:"length"`
	Size      int64  `json:"size"`
	Session   string `json:"session"`
}

type response struct {
	Name       string `json:"name,omitempty"`
	Data       []byte `json:"data,omitempty"`
	Size       int64  `json:"size,omitempty"`
	Error      string `json:"error,omitempty"`
	Read       bool   `json:"read,omitempty"`
	ReadOffset int64  `json:"readOffset,omitempty"`
	ReadLength int64  `json:"readLength,omitempty"`
}

type upload struct {
	input *io.PipeWriter
	done  chan error
}

func main() {
	// No flags, environment configuration, config files, or diagnostic output.
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64*1024), maximumMessage)
	output := json.NewEncoder(os.Stdout)
	if !scanner.Scan() {
		return
	}
	var credentials request
	if json.Unmarshal(scanner.Bytes(), &credentials) != nil || credentials.Password == "" {
		_ = output.Encode(response{Error: "credentials"})
		return
	}
	password, err := obscure.Obscure(credentials.Password)
	if err != nil {
		_ = output.Encode(response{Error: "credentials"})
		return
	}
	salt, err := obscure.Obscure(credentials.Password2)
	if err != nil {
		_ = output.Encode(response{Error: "credentials"})
		return
	}
	cipher, err := crypt.NewCipher(configmap.Simple{
		"password": password, "password2": salt,
		"filename_encryption": "standard", "directory_name_encryption": "true",
		"filename_encoding": "base32", "suffix": ".bin", "pass_bad_blocks": "false",
	})
	credentials = request{}
	if err != nil {
		_ = output.Encode(response{Error: "credentials"})
		return
	}
	if output.Encode(response{Name: "rclone-crypt-v1.75.2"}) != nil {
		return
	}
	uploads := map[string]*upload{}
	defer func() {
		for _, upload := range uploads {
			_ = upload.input.CloseWithError(errors.New("closed"))
			<-upload.done
		}
	}()
	for scanner.Scan() {
		var req request
		if json.Unmarshal(scanner.Bytes(), &req) != nil {
			return
		}
		result := response{}
		err = nil
		switch req.Op {
		case "encode":
			result.Name = cipher.EncryptFileName(req.Path)
		case "decode":
			result.Name, err = cipher.DecryptFileName(req.Path)
		case "size":
			result.Size, err = cipher.DecryptedSize(req.Size)
		case "decrypt":
			if req.Offset < 0 || req.Length < 0 || req.Length > 16*1024*1024 {
				err = errors.New("range")
				break
			}
			reader, openErr := cipher.DecryptDataSeek(context.Background(), func(_ context.Context, offset, limit int64) (io.ReadCloser, error) {
				if limit < 0 || limit > 17*1024*1024 {
					return nil, errors.New("range")
				}
				if output.Encode(response{Read: true, ReadOffset: offset, ReadLength: limit}) != nil || !scanner.Scan() {
					return nil, io.ErrUnexpectedEOF
				}
				var incoming request
				if json.Unmarshal(scanner.Bytes(), &incoming) != nil || incoming.Op != "data" || int64(len(incoming.Data)) > limit {
					return nil, errors.New("range")
				}
				return io.NopCloser(bytes.NewReader(incoming.Data)), nil
			}, req.Offset, req.Length)
			if openErr != nil {
				err = openErr
				break
			}
			result.Data, err = io.ReadAll(io.LimitReader(reader, req.Length))
			_ = reader.Close()
		case "begin":
			if _, exists := uploads[req.Session]; exists || req.Session == "" {
				err = errors.New("session")
				break
			}
			file, openErr := os.OpenFile(req.Path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
			if openErr != nil {
				err = openErr
				break
			}
			input, writer := io.Pipe()
			encrypted, encryptErr := cipher.EncryptData(input)
			if encryptErr != nil {
				_ = file.Close()
				_ = input.Close()
				_ = writer.Close()
				err = encryptErr
				break
			}
			u := &upload{input: writer, done: make(chan error, 1)}
			uploads[req.Session] = u
			go func() {
				_, copyErr := io.Copy(file, encrypted)
				if syncErr := file.Sync(); copyErr == nil {
					copyErr = syncErr
				}
				if closeErr := file.Close(); copyErr == nil {
					copyErr = closeErr
				}
				_ = input.CloseWithError(copyErr)
				u.done <- copyErr
			}()
		case "append":
			u := uploads[req.Session]
			if u == nil || len(req.Data) > 16*1024*1024 {
				err = errors.New("session")
			} else {
				_, err = u.input.Write(req.Data)
			}
		case "finish", "abort":
			u := uploads[req.Session]
			if u == nil {
				err = errors.New("session")
				break
			}
			delete(uploads, req.Session)
			if req.Op == "abort" {
				_ = u.input.CloseWithError(errors.New("aborted"))
			} else {
				_ = u.input.Close()
			}
			err = <-u.done
		default:
			err = errors.New("operation")
		}
		if err != nil {
			// Never echo rclone errors: they can contain decrypted names or input.
			result = response{Error: "crypt operation failed"}
		}
		if output.Encode(result) != nil {
			return
		}
	}
}
