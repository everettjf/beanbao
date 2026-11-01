# Common requests

The first release accepts a small, explicit set of tasks. It runs only while the phone is unlocked and the screen is on, and checks the actual foreground app after each action.

| Request | Expected result | Model needed |
| --- | --- | --- |
| `Open Settings` | Settings is in the foreground; no settings change. | No |
| `Open Maps` | Maps is in the foreground. | No |
| `Open Contacts` | Contacts is in the foreground; no contact data is read. | No |
| `Open Notes` | Notes is in the foreground. | No |
| `Create note: BeanBao test` | A new note is created and its complete title appears in the Notes list. | No |
| `Search Maps for Golden Gate Bridge` | The matching map marker and place card appear; navigation does not start. | When local actions are insufficient |

`Please open Maps.` is accepted. A request that adds another action, such as `Open Maps and send a message`, is rejected as a whole. Existing Chinese commands remain accepted for compatibility. Sending messages, calls, purchases, payments, deletion, app installation, unlocking, and arbitrary file access are outside the supported task set. Maps screenshots may be sent to the configured model after a sensitive-content check; Notes content is not sent to a model.
