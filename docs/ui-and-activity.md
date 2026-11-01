# UI and activity design

The main screen is organized around one request: type or dictate, review the text, then start. Current task status and recent activity sit below the composer. Model settings and the Volume Down shortcut remain available without competing with the primary action.

## Activity in the current release

Activity summarizes the Agent's existing private on-device audit. It shows a task category, outcome, and time. The app does not save the request, note text, Maps place, screenshot, model response, or API key in this view. A Maps or Notes task that fails before text entry is labeled generically so the UI does not claim it completed a specific action. The audit is bounded and can rotate; Activity is a recent operational log, not a permanent record.

## When to add sessions

Tasks are currently independent. A chat bubble UI or named sessions would suggest that BeanBao remembers prior turns and can safely interpret references like “do that again,” which it cannot. Add sessions when a multi-turn planner exists and the user can see exactly which prior turns are being reused.

A future session design should include explicit session creation and switching, a visible context boundary, per-session history deletion, a bounded retention setting, and a way to start a fresh task without prior context. Each action must still pass the existing Bridge policy and fresh-screen checks. A model response or prior session turn must never become permission for an otherwise disallowed action.
