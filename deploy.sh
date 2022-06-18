#!/usr/bin/env sh

# 确锟斤拷锟脚憋拷锟阶筹拷锟斤拷锟斤拷锟侥达拷锟斤拷
set -e

# 锟斤拷锟缴撅拷态锟侥硷拷 , yarn docs:build
npm run docs:build
rm -rf ../blog/dist/*

# 锟斤拷build锟斤拷锟缴碉拷dist目录锟斤拷锟斤拷锟斤拷锟斤拷一锟斤拷目录锟斤拷
cp -rf dist ../blog/

# 锟斤拷锟斤拷锟斤拷锟缴碉拷锟侥硷拷锟斤拷
cd ../blog/dist

# git锟斤拷始锟斤拷锟斤拷每锟轿筹拷始锟斤拷锟斤拷影锟斤拷锟斤拷锟斤拷
git init
git add -A
git commit -m 'deploy'
git branch -M main

# 锟斤拷锟斤拷锟斤拷锟揭拷锟斤拷锟� https://USERNAME.github.io
git push -f git@github.com:it235/it235.github.io.git main