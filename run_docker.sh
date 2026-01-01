docker run -it --rm --name ai-yue-gp \
  --shm-size 24g --gpus all \
  -p 7865:7860 \
  -v ./ai-yue-gp:/workspace \
  -e YUEGP_PROFILE=3 \
  -e YUEGP_ENABLE_ICL=0 \
  -e YUEGP_TRANSFORMER_PATCH=0 \
  -e YUEGP_AUTO_UPDATE=1 \
  olilanz/ai-yue-gp
