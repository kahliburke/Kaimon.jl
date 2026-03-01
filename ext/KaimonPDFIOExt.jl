module KaimonPDFIOExt

import PDFIO
import Kaimon
import Logging

function Kaimon._extract_pdf_text(path::String)::Union{String,Nothing}
    doc = try
        PDFIO.pdDocOpen(path)
    catch e
        @warn "PDFIO: failed to open PDF" file=basename(path) exception=e
        return nothing
    end
    try
        io = IOBuffer()
        for i in 1:PDFIO.pdDocGetPageCount(doc)
            try
                page = PDFIO.pdDocGetPage(doc, i)
                Logging.with_logger(Logging.NullLogger()) do
                    PDFIO.pdPageExtractText(io, page)
                end
            catch
                # Skip pages that fail (font encoding issues, etc.)
            end
        end
        text = String(take!(io))
        isempty(strip(text)) ? nothing : text
    finally
        PDFIO.pdDocClose(doc)
    end
end

end # module
