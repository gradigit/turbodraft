# Image Size Limits

**Status:** pending
**Priority:** p2
**Tags:** feature, images, ux

## Problem Statement

macOS retina screenshots can produce 30-50MB PNGs after TIFF→PNG conversion. These are too large for Claude's vision API (max ~20MB / 8000px per side) and waste memory during editing.

## Desired Behavior

When a user pastes or drags an image that exceeds size limits, TurboDraft should **refuse the image and show an error** — not silently accept or downscale it.

## Implementation Notes

- Check image dimensions and/or file size in `saveTempImageBackground()` or `insertImages()`
- Show a non-modal alert or inline error (e.g., brief overlay message near the editor)
- Suggested thresholds: 20MB file size or 8000px on longest side (match Claude vision API limits)
- Consider checking before the background conversion to avoid wasted work

## Acceptance Criteria

- [ ] Oversized images are rejected with a clear error message
- [ ] Error message explains why the image was refused (too large / too many pixels)
- [ ] Normal-sized images continue to work unchanged
- [ ] No silent data loss — user always knows when an image was rejected
