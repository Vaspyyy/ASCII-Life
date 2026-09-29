# People and conversation

Milestone 4 gives the existing village residents social state that survives movement, conversations and simulation advancement within the running session. Identity and relationships derive from the world seed and stable resident identities. Save files and generational events are still future work.

## Talking and learning

Approach an awake outdoor resident, face them and press **F**. A person must be within seven metres, at a similar elevation and visible past terrain and building walls. The prompt sits in the control area rather than floating over a person's head. Strangers appear as "Villager" until they introduce themselves.

Type a short phrase and press **Enter**. **Backspace** edits it; **Escape** leaves. The world clock pauses while a conversation or journal is open. This is a reading pause, not a player time skip. Once closed, residents continue their schedules.

The deliberately small English grammar accepts these intents, with case and ordinary punctuation ignored:

| Intent | Examples |
| --- | --- |
| Greeting | `hello`, `good morning` |
| Introduction | `name`, `what is your name?` |
| Public work | `work`, `what do you do?` |
| Family | `family`, `tell me about your family` |
| News and beliefs | `news`, `what have you heard?`, `ask about food` |
| Ambition | `plans`, `what do you want?` |
| Offer assistance | `help`, `can I help?` |
| Social response | `thanks`, `sorry`, `you are rude` |
| Leave | `goodbye` |

Unsupported input receives a grammar hint; it does not invent an answer. Offers of help expose the person's public work. They do not create quests, accept contracts, or claim the player has already performed work.

**J** opens the journal. It starts empty and records only disclosed information with the speaker and time learned. A heard belief remains a sourced claim; learning it does not make it world truth. Private requests refused by a stranger add no hidden facts. **N/P** page through the entries; **J/Escape** closes the journal.

Input follows the compositor's XKB layout, including modifiers, rather than assuming a US keyboard. The current grammar and embedded glyph set accept printable ASCII only. IME composition, non-ASCII text, clipboard paste and held-key repeat are not implemented.

## Simulation boundary

Each resident has deterministic caution, sociability, ambition and patience. Caution affects reserve interpretation and disclosure thresholds; ambition changes the work needed for a personal goal; sociability affects the distance at which news is exchanged; patience influences confidence in retellings. Partners, parents, children and siblings are linked through the existing households. Links are reciprocal and refer to the other person's role.

The opening food assessment uses the village's real stock and daily demand. The keeper sees a count; a farmer can interpret those same stores more cautiously. A working keeper recounts once per day. Work and harvest observations derive from actual simulation activity and production. Nearby awake residents can relay that knowledge, retaining the immediate teller, original witness, event, confidence and uncertainty. Older rumors cannot replace a newer event for the same topic.

Goals track hours of relevant work or, for children, visiting and learning about village trades. NPC exchanges build bounded relationship history. Each resident retains up to six salient structured memories and three current knowledge topics. Repeated greetings create no trust. Insults damage trust and change subsequent replies; family and personal plans require meaningful positive history. The positive-action API is exercised by deterministic checks, but performing helpful work or keeping contracts as a player belongs to a later milestone. Saying `help`, `thanks` or `sorry` does not fabricate it.

`people.zig` owns bounded social state independently of the native platform and renderer. `world_clock.zig` advances the existing village economy and schedules to each absolute hour before observing and propagating social information. A large development clock step and smaller frame updates therefore visit the same social checkpoints.

`dialogue.zig` turns supported phrases into intents, asks social state for disclosures and paints glyph panels. `interaction.zig` provides proximity and visibility gating shared with resident rendering. There is no remote conversation service, scripted dialogue bundle, quest database or omniscient player journal.

Development reports intentionally expose internal state for QA. `--people-report`, `--talk-to`, `--say`, `--simulate-days` and `--journal` are documented in [BUILD.md](BUILD.md). They are separate from knowledge learned in ordinary play.

## Keyboard dependency decision

The one added dependency is **libxkbcommon**, isolated in the Wayland platform module. It compiles compositor-provided keymaps and applies layout/modifier state. Implementing that grammar and international keyboard behavior in-house would be a substantial platform subsystem; a hard-coded key table would fail ordinary configured layouts. It does not enter deterministic generation or simulation, and can be replaced behind the same ordered text-event interface.

An isolated ReleaseSmall measurement grew the stripped ELF from **202,328 to 204,312 bytes (+1,984)** for input integration alone. The host library is **440,488 bytes**, or **167,044 bytes** under `xz -9`; its libffi dependency was already bundled. [SIZE.md](SIZE.md) records the complete M4 executable and distribution costs, including the library and license notice.
