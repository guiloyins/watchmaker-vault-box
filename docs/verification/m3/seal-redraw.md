# CYD seal progress redraw

During the first mixed CYD A and Browser B round, A reported seeing **Controls disabled** while holding the seal. The host observed 18 short A holds, lasting roughly 100–309 ms at observer resolution, while both controllers were fresh and the game was unpaused. The first captured positive hold progress was 1–3 ms. The observer does not measure the CYD owner-loop timing or establish the cause of the short holds. [Host observation](cyd-a-mixed-seal-observer-02.json)

The seal renderer inserted its progress fill when elapsed time first became positive and removed it when the hold ended. Both changes shifted the later hold and footer objects through the Board’s sequential LVGL primitive slots. The renderer now reserves one progress slot after the footer. When elapsed progress is absent it draws a one-pixel fill in the existing bar interior color. At positive progress it uses the existing green fill and width calculation. [Seal renderer](../../../firmware/components/vault_display/vault_display.cpp) · [Earlier maze redraw fix](key-redraw.md)

A native probe compiled the production Board and pinned LVGL 9.2.2 with a fake 240 × 320 RGB565 panel. It tested 19 frames for each role, including local hold, acknowledged hold, progress updates, loss and release. All 38 full framebuffers matched the previous renderer byte for byte, with a combined SHA-256 of `f4f6a970c800c92e3d271780a30cc88117bca450df06be5d165ecfb5fb05c4b5`. The new renderer used 33 primitive slots throughout the sequence. The previous renderer used 32 or 33 depending on whether progress was visible.

| Transition | Previous renderer | Fixed progress slot |
| --- | ---: | ---: |
| Local hold awaiting acknowledgment | 12,540 pixels / 6 flushes | 12,540 pixels / 6 flushes |
| Acknowledged local hold | 2,492 / 2 | 2,492 / 2 |
| Progress 0 → 100 ms | 76,800 / 32 | 121 / 1 |
| Progress 100 → 250 ms | 297 / 1 | 297 / 1 |
| Progress 250 → 500 ms | 594 / 1 | 594 / 1 |
| Progress disappears | 76,800 / 32 | 3,814 / 3 |
| Hold starts and progress is already 250 ms | 76,800 / 32 | 16,057 / 9 |
| Hold is lost and the control becomes disabled | 76,800 / 32 | 16,057 / 9 |
| Unchanged seal | 0 / 0 | 0 / 0 |

The probe also tried appending a conditional progress fill. That variant repainted 242 pixels in two flushes on 0 → 100 ms and added or removed a primitive. The fixed slot also preserves the position of any diagnostic object appended after the seal render. The native checks establish rendering behavior. The physical retest measures uninterrupted accepted hold, deliberate cancellation and full shared qualification.

The normal unit-specific image was installed with all three image hashes verified. Two connection attempts failed before writing; the third identified the approved MAC and completed. NVS was not initialized. Four separate normal USB v1 opens retained one new boot ID, configured provisioning, service revision 5 and the exact service-exit receipt. The physical hold retest is pending. [Build and installation](seal-redraw-build.json) · [USB evidence](seal-redraw-usb.json)

After role reclaim and resume, a 100 ms host observer recorded CYD hold intervals up to 8,524 ms. During one interval, browser B held for approximately 612 ms and released; shared progress cleared while A was still held, and the game remained at the seal with no release requested. Several A hold intervals ended; the host cannot distinguish intentional lifts from unwanted touch loss. A continuous 15-second hold and full qualification are not established. The user subsequently confirmed that Controls disabled appeared while the finger remained down. Continuous-hold acceptance failed; the host-only observer cannot determine the cancellation cause. [Retest observations](seal-redraw-hold-retest.json) · [Raw host states](cyd-a-mixed-seal-observer-03.json)
