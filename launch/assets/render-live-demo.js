const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { pathToFileURL } = require("url");

const assetDir = __dirname;
const htmlPath = path.join(assetDir, "live-demo.html");
const frameDir = path.join(assetDir, "live-demo-frames");
const mp4Path = path.join(assetDir, "codex-claude-handoff-live-demo.mp4");
const gifPath = path.join(assetDir, "codex-claude-handoff-live-demo.gif");
const posterPath = path.join(assetDir, "codex-claude-handoff-live-demo-poster.png");
const ffmpegPath = process.env.FFMPEG_PATH;
const chromePath =
  process.env.CHROME_PATH ||
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";

if (!ffmpegPath || !fs.existsSync(ffmpegPath)) {
  throw new Error("Set FFMPEG_PATH to a working ffmpeg executable.");
}

if (!fs.existsSync(chromePath)) {
  throw new Error(`Chrome not found: ${chromePath}`);
}

async function main() {
  fs.mkdirSync(frameDir, { recursive: true });

  const durations = [4, 6, 6, 6, 7, 7, 5, 6, 7, 6];

  for (let scene = 0; scene < durations.length; scene += 1) {
    const outputPath = path.join(frameDir, `scene-${scene}.png`);
    const url = `${pathToFileURL(htmlPath).href}?scene=${scene}`;
    const screenshot = spawnSync(
      chromePath,
      [
        "--headless=new",
        "--disable-gpu",
        "--hide-scrollbars",
        "--allow-file-access-from-files",
        "--force-device-scale-factor=1",
        "--window-size=1920,1080",
        `--screenshot=${outputPath}`,
        url,
      ],
      { stdio: "inherit" },
    );

    if (screenshot.status !== 0 || !fs.existsSync(outputPath)) {
      throw new Error(`Chrome failed to render scene ${scene}.`);
    }
  }

  fs.copyFileSync(path.join(frameDir, "scene-0.png"), posterPath);

  const inputArgs = [];
  const filterParts = [];
  const labels = [];

  durations.forEach((duration, index) => {
    inputArgs.push(
      "-loop",
      "1",
      "-t",
      String(duration),
      "-i",
      path.join(frameDir, `scene-${index}.png`),
    );
    const fadeOutStart = Math.max(0, duration - 0.25);
    filterParts.push(
      `[${index}:v]fps=30,format=yuv420p,` +
        `fade=t=in:st=0:d=0.25,fade=t=out:st=${fadeOutStart}:d=0.25,` +
        `setpts=PTS-STARTPTS[v${index}]`,
    );
    labels.push(`[v${index}]`);
  });

  filterParts.push(
    `${labels.join("")}concat=n=${durations.length}:v=1:a=0[outv]`,
  );

  const video = spawnSync(
    ffmpegPath,
    [
      "-y",
      ...inputArgs,
      "-filter_complex",
      filterParts.join(";"),
      "-map",
      "[outv]",
      "-c:v",
      "libx264",
      "-preset",
      "medium",
      "-crf",
      "20",
      "-movflags",
      "+faststart",
      "-pix_fmt",
      "yuv420p",
      mp4Path,
    ],
    { stdio: "inherit" },
  );

  if (video.status !== 0) {
    process.exit(video.status || 1);
  }

  const gif = spawnSync(
    ffmpegPath,
    [
      "-y",
      "-i",
      mp4Path,
      "-vf",
      "fps=8,scale=960:-1:flags=lanczos,split[s0][s1];" +
        "[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer",
      "-loop",
      "0",
      gifPath,
    ],
    { stdio: "inherit" },
  );

  if (gif.status !== 0) {
    process.exit(gif.status || 1);
  }

  fs.rmSync(frameDir, { recursive: true, force: true });
  console.log(`Rendered ${mp4Path}`);
  console.log(`Rendered ${gifPath}`);
  console.log(`Rendered ${posterPath}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
