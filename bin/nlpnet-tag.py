#!/usr/bin/env python
# -*- coding: utf-8 -*-

"""
This script will run a POS, NER or SRL tagger on the input data and print
the results to stdout.

"""

import argparse
import logging
from itertools import izip

# Attardi: allow executing from anywhere without installing package
import sys
import os
srcdir = os.path.dirname(os.path.realpath(__file__)) + '/../'
sys.path.append(srcdir + 'build/lib.linux-x86_64-2.7')

import nlpnet
import nlpnet.taggers
import nlpnet.utils as utils
import nlpnet.config as config

def interactive_running(task):
    """
    This function provides an interactive environment for running the system.
    It receives text from the standard input, tokenizes it, and calls the function
    given as a parameter to produce an answer.
    
    :param task: either 'pos', 'srl' or 'ner'
    """
    task_lower = task.lower()
    if task_lower == 'pos':
        tagger = nlpnet.taggers.POSTagger()
    elif task_lower == 'srl':
        tagger = nlpnet.taggers.SRLTagger()
    elif task_lower == 'ner':
        tagger = nlpnet.taggers.NERTagger()
    else:
        raise ValueError('Unknown task: %s' % task)
    
    while True:
        try:
            text = raw_input()
        except KeyboardInterrupt:
            break
        except EOFError:
            break
        
        if type(text) is not unicode:
            text = unicode(text, 'utf-8')
        
        result = tagger.tag(text)        
        _print_tagged(result, task)

def process_input(task):
    """
    This function reads input from stdin and processes sentences.
    
    :param task: either 'pos', 'srl' or 'ner'
    """
    task_lower = task.lower()
    if task_lower == 'pos':
        tagger = nlpnet.taggers.POSTagger()
    elif task_lower == 'srl':
        tagger = nlpnet.taggers.SRLTagger()
    elif task_lower == 'ner':
        tagger = nlpnet.taggers.NERTagger()
    else:
        raise ValueError('Unknown task: %s' % task)
    
    result = tagger.tag()        
    _print_tagged(result, task)

def _print_tagged(tagged_sents, task):
    """
    Prints the tagged text to stdout.
    
    :param tagged_sents: sentences tagged according to any of nlpnet taggers.
    :param task: the tagging task (either 'pos', 'srl' or 'ner')
    """
    if task == 'pos':
        _print_tagged_pos(tagged_sents)
    elif task == 'srl':
        _print_tagged_srl(tagged_sents)
    elif task == 'ner':
        _print_tagged_ner(tagged_sents)
    else:
        raise ValueError('Unknown task: %s' % task)
    
def _print_tagged_pos(tagged_sents):
    """Prints one sentence per line as token_tag"""
    # for sent in tagged_sents:
    #     s = ' '.join('_'.join(item) for item in sent)
    #     print s

    # print in tsv
    for sent in tagged_sents:
        for token in sent:
            print '\t'.join([item.encode('utf-8') for item in token])
        print

def _print_tagged_srl(tagged_sents):
    for sent in tagged_sents:
        print ' '.join(sent.tokens).encode('utf-8')
        for predicate, arg_structure in sent.arg_structures:
            print predicate.encode('utf-8')
            for label in arg_structure:
                argument = ' '.join(arg_structure[label])
                line = '\t%s: %s' % (label, argument)
                print line.encode('utf-8')
        print

def _print_tagged_ner(tagged_sents):
    """Prints one token per line as token\ttag"""
    for sent in tagged_sents:
        for tok, tag in sent:
            print tok[0] + '\t' + tag # tok is (form, POS)
        print

if __name__ == '__main__':
    
    parser = argparse.ArgumentParser()
    parser.add_argument('task', help='Task for which the network should be used.', 
                        type=str, choices=['srl', 'pos', 'ner'])
    parser.add_argument('data', help='Directory containing trained models.', type=str)
    parser.add_argument('-v', help='Verbose mode', action='store_true', dest='verbose')
    parser.add_argument('--no-repeat', dest='no_repeat', action='store_true',
                        help='Forces the classification step to avoid repeated argument labels (SRL only).')
    args = parser.parse_args()
    
    logging_level = logging.DEBUG if args.verbose else logging.WARNING
    utils.set_logger(logging_level)
    logger = logging.getLogger("Logger")
    config.set_data_dir(args.data)
    
    #interactive_running(args.task)
    process_input(args.task)

