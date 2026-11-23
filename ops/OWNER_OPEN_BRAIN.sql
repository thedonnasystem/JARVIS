-- THE ONE OWNER DECISION for the open brain. Run in the Supabase SQL editor (signed in as the owner).
-- ON  = your own chat with Jarvis and your missions may go to free model providers that do NOT train on prompts and keep no prompt data:
--       Groq, OpenRouter (routed with data_collection = deny) and Cerebras. Client personal data never goes there, whatever this says
--       (it only goes to a self-hosted model, or the task is refused).
-- OFF (default) = Jarvis answers your chat only with a self-hosted model or, if you switched paid providers on, Anthropic. Otherwise it says so.
select public.open_brain_set_owner_chat_free(true);    -- to turn it back off: select public.open_brain_set_owner_chat_free(false);
select public.open_brain_routing();                     -- shows the current settings
-- OPTIONAL second decision: let providers that may train on prompts (Google Gemini free tier) take NON-PRIVATE work only (public research,
-- long public documents). Your chat and client data never go there, whatever this says.
-- select public.open_brain_set_training_nonprivate(true);
