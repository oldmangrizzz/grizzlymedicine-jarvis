import sys
sys.path.insert(0, '/Users/rbhanson/research/jarvis/.venv/lib/python3.12/site-packages')
# Load sentencepiece directly, bypassing pocket-tts beartype
import sentencepiece
sp = sentencepiece.SentencePieceProcessor()
sp.Load(sys.argv[1])
print("vocab_size:", sp.vocab_size())
ids = sp.encode("Ready.", out_type=int)
print("ids for 'Ready.':", ids)
ids2 = sp.encode("JARVIS online.", out_type=int)
print("ids for 'JARVIS online.':", ids2)
