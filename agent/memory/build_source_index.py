import os, json, hashlib, datetime

def get_info(path):
    stats=os.stat(path)
    size=stats.st_size
    mtime=datetime.datetime.fromtimestamp(stats.st_mtime).isoformat()
    with open(path,'rb') as f:
        data=f.read()
    sha256=hashlib.sha256(data).hexdigest()
    ext=os.path.splitext(path)[1].lower()
    language={'\.zig':'zig','\.b+':'bplus','.json':'json'}.get(ext,'unknown')
    file_type='module' if ext=='.zig' else 'program' if ext=='.b+' else 'config'
    return{'path':path,'size':size,'last_write':mtime,'sha256':sha256,'language':language,'type':file_type}

filelist='C:\\B-Plus\\agent\\memory\\filelist.txt'
entries=[]
with open(filelist,'r',encoding='utf-8') as f:
    for line in f:
        p=line.strip()
        if p:
            if os.path.exists(p):
                entries.append(get_info(p))

json_path='C:\\B-Plus\\agent\\memory\\source_index.json'
with open(json_path,'w',encoding='utf-8') as jf:
    json.dump({'files':entries},jf,indent=2)

print('created',json_path)
print('FILES:',len(entries))