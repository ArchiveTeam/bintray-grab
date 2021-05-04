# You should only need to run this during the dev process
f = open("bintray.lua")
o = open("bintray_noge.lua", "w")
is_in_dnw = False
for line in f:
    if line.rstrip() == "wget.callbacks.get_urls = function(file, url, is_css, iri)":
        is_in_dnw = True
    else:
        if is_in_dnw:
            if line.rstrip() == "end":
                is_in_dnw = False
            # Else do nothing
        else:
            o.write(line)