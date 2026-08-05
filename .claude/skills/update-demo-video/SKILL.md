---
name: update-demo-video
description: Replace the marketing video on the Learn More page of the public TIBCO Developer Hub demo. Trigger when the user wants to update / upload / swap the demo video, the Learn More video, the marketing video, or push a new VideoResources/*.mov|.m4v to the Lightsail demo host. Re-encodes the source to a web-ready mp4 and scp's it to the host's gitignored media dir that Caddy serves. NOT for building/redeploying the demo image (use create-demo-environment).
---

# update-demo-video

Swap the marketing video shown on the demo's **Learn More** page. The video is **not** in git or the
Docker image — it is served by Caddy straight from a gitignored `./media` dir on the host (bind-mounted
to `/srv/media`, exposed at `/tibco/hub/media/*`). So updating it is just: **re-encode → scp → done**.
No image rebuild, no `redeploy.sh`.

Live URL the page embeds:
`https://<demo-domain>/tibco/hub/media/devhub-marketing.mp4`
(referenced by the `<video>` tag in `promotional-material/learn-more/docs/index.md`).

## Host specifics (kept out of git)

The actual domain, static IP, SSH key path, and host clone-dir live **only** in the gitignored
`deploy/demo/LightSail_README.md` (and the user's `HugoNotes.txt`). Read those for the real values before
running the upload. As of this writing they are:

- key: `ssh-key/LightsailDefaultKey-eu-west-1.pem`  ← **never read the `ssh-key/` folder**; only reference the path
- host: `ubuntu@108.132.188.164` (the Lightsail static IP)
- host media dir: `~/tibco-developer-hub-fork/deploy/demo/media/`

Confirm these against the runbook in case the host was rebuilt.

## Steps

### 1. Pick the source and decide copy vs re-encode

Sources live in `VideoResources/`. Probe the chosen master first:

```bash
ffprobe -v error -show_entries stream=codec_type,codec_name,width,height:format=duration,size \
  -of default=noprint_wrappers=1 VideoResources/<SOURCE>
```

- If the video stream is already **H.264** (e.g. the `.m4v` masters), you can stream-copy it (fast):
  `-c:v copy`.
- If it is **ProRes** or anything non-H.264 (e.g. the `.mov` masters), you **must** re-encode the video.
- `.mov` ProRes exports often carry an extra **mjpeg thumbnail** video stream and a **data** stream —
  map explicitly (`-map 0:v:0 -map 0:a:0`) so only the real video + audio are encoded.

### 2. Produce the web-ready mp4

Output is always `VideoResources/devhub-marketing.mp4` (the name the page and Caddy expect — keep it
unless you also update `promotional-material/learn-more/docs/index.md`). Target: H.264 high / yuv420p,
720p, AAC 128k, **`+faststart`** (so the browser can start playing / seeking before full download).

Re-encode (ProRes / non-H.264 source):

```bash
ffmpeg -y -i VideoResources/<SOURCE> \
  -map 0:v:0 -map 0:a:0 \
  -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 21 -preset medium \
  -c:a aac -b:a 128k -movflags +faststart \
  VideoResources/devhub-marketing.mp4
```

Stream-copy (already-H.264 source — only the audio is re-encoded):

```bash
ffmpeg -y -i VideoResources/<SOURCE> \
  -c:v copy -c:a aac -b:a 128k -movflags +faststart \
  VideoResources/devhub-marketing.mp4
```

Sanity-check the result — expect `h264` + `aac`, the right resolution, and a sane size (the marketing
clip is ~10–20 MB):

```bash
ffprobe -v error -show_entries stream=codec_type,codec_name,width,height:format=duration,size \
  -of default=noprint_wrappers=1 VideoResources/devhub-marketing.mp4
```

### 3. Upload to the host

The file is gitignored, so scp it straight up (overwrites in place). Use the real key/IP/dir from the
runbook:

```bash
KEY=ssh-key/LightsailDefaultKey-eu-west-1.pem
HOST=ubuntu@108.132.188.164
MEDIA=~/tibco-developer-hub-fork/deploy/demo/media

ssh -i "$KEY" "$HOST" "mkdir -p $MEDIA"
scp -i "$KEY" VideoResources/devhub-marketing.mp4 "$HOST":"$MEDIA"/
```

`ssh`/`scp` reach out to the host — if running these for the user, confirm first. Suggest the user run
them via the `! <command>` prompt prefix if an interactive key passphrase is involved.

### 4. (Optional) bounce Caddy

`file_server` reads the bind mount live, so a new file is served immediately — **no restart needed**.
Restart only to bust a stale edge cache:

```bash
ssh -i "$KEY" "$HOST" "cd ~/tibco-developer-hub-fork/deploy/demo && docker compose up -d caddy"
```

### 5. Verify

Expect `206 video/mp4` (range requests work) and a size matching the new file:

```bash
curl -sS -o /dev/null -w '%{http_code} %{content_type} %{size_download}\n' \
  -H 'Range: bytes=0-1' \
  "https://<demo-domain>/tibco/hub/media/devhub-marketing.mp4"   # -> 206 video/mp4 2
```

Then open `https://<demo-domain>/tibco/hub` → Learn More and confirm the new clip plays.

## Notes

- Keep the output filename `devhub-marketing.mp4`. If you rename it, update the `<video>` `src` in
  `promotional-material/learn-more/docs/index.md` (path `/tibco/hub/media/<newname>.mp4`) — these are the
  only two places coupled to the name.
- `dig`/`nslookup` and the `ssh`/`scp`/`curl` calls hit the network — they fail under the command
  sandbox ("Operation not permitted"); rerun with the sandbox disabled.
- This skill only touches the static video. To change the running app, config, or image, see
  `create-demo-environment`.
