#!/usr/bin/env bash
# multi-turn-test.sh — drives a growing multi-turn conversation against a
# given Ollama model via /api/chat (stateful message history), logging
# per-turn latency/token counts. Meant to be run while monitor.sh samples
# RAM/VRAM in parallel, to see whether context growth (not just initial
# allocation) causes instability at a given num_ctx.
#
# Usage: ./multi-turn-test.sh <model_name> <output_prefix>
# Produces: <output_prefix>.jsonl (per-turn raw responses)
#           <output_prefix>_summary.csv (turn,latency_s,prompt_tokens,gen_tokens,cumulative_tokens)

set -euo pipefail

MODEL="${1:?Usage: multi-turn-test.sh <model_name> <output_prefix> [timeout_s] [num_turns]}"
PREFIX="${2:?Usage: multi-turn-test.sh <model_name> <output_prefix> [timeout_s] [num_turns]}"
TIMEOUT="${3:-240}"
NUM_TURNS="${4:-10}"

# A fixed pool of prompts mixing chat/coding/summarization, escalating in
# length, to grow the conversation's token count meaningfully turn by turn.
ALL_PROMPTS=(
  "Hi, I'm tuning a local LLM setup. Briefly introduce yourself."
  "Explain what a KV cache is and why it matters for context length."
  "Write a Python function that reverses a linked list, with comments."
  "Now write unit tests for that function using pytest."
  "Summarize our conversation so far in 3 bullet points."
  "Refactor the linked list function to be iterative instead of recursive, if it wasn't already, and explain the tradeoffs."
  "Write a 150-word explanation of mixture-of-experts models for a beginner."
  "Based on everything discussed, write a short README section documenting the reverse-linked-list utility."
  "What potential edge cases did we miss in the tests? List at least 4."
  "Give a final summary of this entire conversation in 5 bullet points."
)
PROMPTS=("${ALL_PROMPTS[@]:0:$NUM_TURNS}")

MESSAGES="[]"
echo "turn,latency_s,prompt_tokens,gen_tokens,cumulative_tokens" > "${PREFIX}_summary.csv"
: > "${PREFIX}.jsonl"

for i in "${!PROMPTS[@]}"; do
  turn=$((i + 1))
  prompt="${PROMPTS[$i]}"

  # Append user message to running history.
  MESSAGES=$(python3 -c "
import json, sys
msgs = json.loads(sys.argv[1])
msgs.append({'role': 'user', 'content': sys.argv[2]})
print(json.dumps(msgs))
" "$MESSAGES" "$prompt")

  payload=$(python3 -c "
import json, sys
print(json.dumps({'model': sys.argv[1], 'messages': json.loads(sys.argv[2]), 'stream': False}))
" "$MODEL" "$MESSAGES")

  echo "  turn $turn: sending (${#prompt} chars prompt)..."
  start=$(date +%s.%N)
  resp=$(curl -s --max-time "$TIMEOUT" http://localhost:11434/api/chat -d "$payload")
  end=$(date +%s.%N)
  latency=$(echo "$end - $start" | bc)

  echo "$resp" >> "${PREFIX}.jsonl"

  if [[ -z "$resp" ]]; then
    echo "  turn $turn: EMPTY RESPONSE (possible stall/timeout)" >&2
    echo "$turn,TIMEOUT,,," >> "${PREFIX}_summary.csv"
    break
  fi

  reply=$(echo "$resp" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('message',{}).get('content',''))
except Exception as e:
    print('PARSE_ERROR:',e)
")
  prompt_tokens=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('prompt_eval_count',''))" 2>/dev/null || echo "")
  gen_tokens=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('eval_count',''))" 2>/dev/null || echo "")

  echo "$turn,$latency,$prompt_tokens,$gen_tokens,$((${prompt_tokens:-0} + ${gen_tokens:-0}))" >> "${PREFIX}_summary.csv"

  # Append assistant reply to running history for next turn's context.
  MESSAGES=$(python3 -c "
import json, sys
msgs = json.loads(sys.argv[1])
msgs.append({'role': 'assistant', 'content': sys.argv[2]})
print(json.dumps(msgs))
" "$MESSAGES" "$reply")

  echo "  turn $turn: ${latency}s, prompt_tokens=$prompt_tokens gen_tokens=$gen_tokens"
done

echo "done -> ${PREFIX}_summary.csv"
