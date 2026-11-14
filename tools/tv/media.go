package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const youtubeFormat = "bv*[vcodec^=avc1][height<=1080]+ba[acodec^=mp4a]/b[vcodec^=avc1][acodec^=mp4a][height<=1080]/bv*[height<=1080]+ba/b[height<=1080]/b"

func run(ctx context.Context, name string, args ...string) ([]byte, error) {
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := stderr.String()
		if len(msg) > 1000 {
			msg = msg[len(msg)-1000:]
		}
		return nil, fmt.Errorf("%s: %w: %s", filepath.Base(name), err, strings.TrimSpace(msg))
	}
	return stdout.Bytes(), nil
}

type probe struct {
	Streams []struct {
		CodecType string `json:"codec_type"`
		CodecName string `json:"codec_name"`
		PixFmt    string `json:"pix_fmt"`
		Height    int    `json:"height"`
	} `json:"streams"`
	Format struct {
		Duration string `json:"duration"`
	} `json:"format"`
}

func (s *server) probe(ctx context.Context, headers []string, input string) (probe, error) {
	// ffprobe ships next to ffmpeg
	ffprobe := strings.TrimSuffix(s.cfg.FFmpeg, "ffmpeg") + "ffprobe"
	args := append(append([]string{"-v", "error"}, headers...),
		"-show_entries", "stream=codec_type,codec_name,pix_fmt,height:format=duration", "-of", "json", input)
	var p probe
	out, err := run(ctx, ffprobe, args...)
	if err != nil {
		return p, err
	}
	return p, json.Unmarshal(out, &p)
}

// prepare turns c into one browser-friendly MP4 in the cache dir and returns
// its file name and duration in ms.
func (s *server) prepare(ctx context.Context, c candidate) (string, int64, error) {
	var input string
	var headers []string
	if c.Kind == "youtube" {
		dir := filepath.Join(s.cfg.CacheDir, "download")
		os.RemoveAll(dir)
		defer os.RemoveAll(dir)
		args := append(append([]string{}, s.cfg.YtDlpArgs...),
			"--no-playlist", "--no-progress", "-f", youtubeFormat, "--merge-output-format", "mp4",
			"--ffmpeg-location", s.cfg.FFmpeg, "-o", filepath.Join(dir, "video.%(ext)s"),
			"--print", "after_move:filepath", c.ref)
		out, err := run(ctx, s.cfg.YtDlp, args...)
		if err != nil {
			return "", 0, err
		}
		input = strings.TrimSpace(string(out))
	} else {
		input = strings.TrimSuffix(s.cfg.JellyfinURL, "/") + "/Videos/" + c.ref + "/stream?static=true"
		headers = []string{"-headers", s.jellyfinAuth() + "\r\n"}
	}

	p, err := s.probe(ctx, headers, input)
	if err != nil {
		return "", 0, err
	}
	videoArgs := []string{"-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-pix_fmt", "yuv420p", "-vf", "scale=-2:'min(1080,trunc(ih/2)*2)'"}
	audioArgs := []string{"-c:a", "aac", "-b:a", "192k", "-ac", "2"}
	hasVideo, hasAudio := false, false
	for _, st := range p.Streams {
		switch {
		case st.CodecType == "video" && !hasVideo:
			hasVideo = true
			if st.CodecName == "h264" && (st.PixFmt == "yuv420p" || st.PixFmt == "yuvj420p") && st.Height <= 1080 {
				videoArgs = []string{"-c:v", "copy"}
			}
		case st.CodecType == "audio" && !hasAudio:
			hasAudio = true
			if st.CodecName == "aac" {
				audioArgs = []string{"-c:a", "copy"}
			}
		}
	}
	if !hasVideo {
		return "", 0, fmt.Errorf("%s has no video stream", input)
	}
	name := fmt.Sprintf("%s-%d.mp4", strings.NewReplacer(":", "-", "/", "-").Replace(c.ID), time.Now().Unix())
	part := filepath.Join(s.cfg.CacheDir, name+".part")
	args := append([]string{"-hide_banner", "-loglevel", "error", "-y"}, headers...)
	args = append(args, "-i", input, "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn")
	args = append(append(args, videoArgs...), audioArgs...)
	args = append(args, "-movflags", "+faststart", "-f", "mp4", part)
	if _, err := run(ctx, s.cfg.FFmpeg, args...); err != nil {
		os.Remove(part)
		return "", 0, err
	}
	out, err := s.probe(ctx, nil, part)
	if err != nil {
		os.Remove(part)
		return "", 0, err
	}
	secs, err := strconv.ParseFloat(out.Format.Duration, 64)
	if err != nil || secs <= 0 {
		os.Remove(part)
		return "", 0, fmt.Errorf("no duration for %s", part)
	}
	if err := os.Rename(part, filepath.Join(s.cfg.CacheDir, name)); err != nil {
		return "", 0, err
	}
	return name, int64(math.Round(secs * 1000)), nil
}
